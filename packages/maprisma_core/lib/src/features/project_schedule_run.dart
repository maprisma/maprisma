/// What a project's timer runs (task 101): `plugin schedule-run <id>`.
///
/// The store has one owner, whoever holds the exclusive lock on
/// `ai-project-center/` (released by the kernel when that process ends, so
/// no stale PID or socket can be taken over). The trigger leaves a request
/// in the private spool `ai-project-center/schedule/` and then either
/// becomes the owner itself (Maprisma is closed) and handles the spool, or
/// waits until the running owner claimed its request.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core.dart';
import '../posix_ffi.dart';
import '../protocol.dart';
import 'ai_project_center.dart';

final _projectId = RegExp(r'^[0-9a-f]{32}$');

String _same(String text) => text;

String _random() => List.generate(
  8,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Writes the request of a trigger of [id] at [at] into the spool of the
/// store in [dataDirectory]: written under a temporary name and renamed, so
/// the owner never reads half a request (a draft that failed is removed).
/// Returns its path.
String writeScheduleRequest(
  String dataDirectory,
  String id,
  DateTime at, {
  Posix? posix,
}) {
  if (!_projectId.hasMatch(id)) throw ArgumentError.value(id);
  final io = posix ?? Posix();
  final spool = p.join(dataDirectory, 'ai-project-center', 'schedule');
  final dir = io.privateDirectory(spool);
  final name = '$id.${_random()}.request';
  final temporary = '.$name.tmp';
  var created = false;
  try {
    try {
      const create = 0x40, exclusive = 0x80, writeOnly = 0x1;
      final fd = io.openAt(
        dir,
        temporary,
        writeOnly | create | exclusive | Posix.noFollow,
        0x180,
      );
      created = true;
      try {
        io.write(
          fd,
          utf8.encode(
            jsonEncode({'id': id, 'at': at.toUtc().toIso8601String()}),
          ),
        );
        io.sync(fd);
      } finally {
        io.close(fd);
      }
    } finally {
      io.close(dir);
    }
    File(p.join(spool, temporary)).renameSync(p.join(spool, name));
  } on Object {
    if (created) {
      try {
        File(p.join(spool, temporary)).deleteSync();
      } on FileSystemException {
        // Gone already.
      }
    }
    rethrow;
  }
  return p.join(spool, name);
}

/// The headless owner: handles the spool until its runs ended and no
/// request waits, or until [stop] completes; then shuts down like the app's
/// backend (a run still working is paused within the bounded shutdown).
Future<void> serveScheduledRuns(
  AiProjectCenterPlugin plugin, {
  Future<void>? stop,
  Duration poll = const Duration(seconds: 2),
}) async {
  var stopped = false;
  unawaited(stop?.then((_) => stopped = true));
  var quiet = 0;
  while (!stopped) {
    final handled = await plugin.takeScheduleRequests();
    // Two quiet polls in a row without work: a request written just now
    // still gets its turn.
    quiet = handled == 0 && plugin.idle ? quiet + 1 : 0;
    if (quiet >= 2) break;
    await Future.any([Future<void>.delayed(poll), ?stop]);
  }
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await plugin.shutdown();
      return;
    } on ServiceError {
      // Processes still stopping: asked again.
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}

/// One trigger of [id]'s timer. [open] opens the store as its owner and
/// throws `ServiceError('project_center_busy')` while another process owns
/// it. Results: `owner` (it was the owner and has served the spool),
/// `handed_over` (the running owner claimed the request) or `timeout` (no
/// owner took it in [wait]; the request was withdrawn, the user notified)
/// or `unwritten` (its request could not be written; the user notified).
Future<String> scheduleTrigger({
  required String id,
  required String dataDirectory,
  required AiProjectCenterPlugin Function() open,
  required Future<void> Function(AiProjectCenterPlugin owner) serve,
  DateTime Function()? clock,
  Duration wait = const Duration(seconds: 60),
  Duration step = const Duration(milliseconds: 500),
  void Function(String title, String body)? notify,
  String Function(String text) translate = _same,
  Posix? posix,
}) async {
  final String request;
  try {
    request = writeScheduleRequest(
      dataDirectory,
      id,
      (clock ?? DateTime.now)(),
      posix: posix,
    );
  } on Object catch (error) {
    // Without its request no owner can run it: not silent.
    stderr.writeln('Maprisma schedule-run $id: the request: $error');
    notify?.call(
      translate('Maprisma: a scheduled project did not run'),
      translate(
        'The scheduled run could not be handed over to Maprisma. Its timer starts it again at the next planned time.',
      ),
    );
    return 'unwritten';
  }
  final deadline = DateTime.now().add(wait);
  while (true) {
    AiProjectCenterPlugin? owner;
    try {
      owner = open();
    } on ServiceError catch (error) {
      if (error.code != 'project_center_busy') rethrow;
    }
    if (owner != null) {
      // Its own request is in the spool, with any other one.
      await serve(owner);
      return 'owner';
    }
    // Claimed (renamed) by the running owner.
    if (FileSystemEntity.typeSync(request, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return 'handed_over';
    }
    if (DateTime.now().isAfter(deadline)) {
      try {
        File(request).deleteSync();
      } on FileSystemException {
        return 'handed_over'; // claimed at the last moment
      }
      notify?.call(
        translate('Maprisma: a scheduled project did not run'),
        translate(
          'Maprisma is open but did not take the scheduled run. Open its Projects page and try again.',
        ),
      );
      return 'timeout';
    }
    await Future<void>.delayed(step);
  }
}

/// `schedule-run <id>`: the program a project's systemd timer starts.
Future<int> runScheduledProject(List<String> args) async {
  if (args.length != 1 || !_projectId.hasMatch(args.single)) {
    stderr.writeln('usage: schedule-run <project id>');
    return 2;
  }
  final id = args.single;
  final service = CoreService(
    environment: Platform.environment,
    migrate: false,
    featureWorker: true,
  );
  final stop = Completer<void>();
  void onSignal(ProcessSignal _) {
    if (!stop.isCompleted) stop.complete();
  }

  final term = ProcessSignal.sigterm.watch().listen(onSignal);
  final interrupt = ProcessSignal.sigint.watch().listen(onSignal);
  try {
    final result = await scheduleTrigger(
      id: id,
      dataDirectory: service.identity.dataDir,
      open: () => service.projectCenter,
      serve: (owner) => serveScheduledRuns(owner, stop: stop.future),
      notify: service.desktop.projectScheduler.notify,
      translate: service.i18n.text,
    );
    stdout.writeln('Maprisma schedule-run $id: $result');
    return result == 'timeout' || result == 'unwritten' ? 1 : 0;
  } on Object catch (error) {
    stderr.writeln('Maprisma schedule-run $id: $error');
    return 1;
  } finally {
    await term.cancel();
    await interrupt.cancel();
    service.dispose();
  }
}
