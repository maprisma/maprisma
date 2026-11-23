/// Project schedules on the desktop (task 101): one systemd user timer per
/// scheduled AI project, so a run starts also while Maprisma is closed.
/// macOS later gets its launchd agent behind the same interface.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'desktop.dart' show whichIn;
import 'features/project_supervisor.dart' show projectScheduleCommand;
import 'identity.dart';
import 'model_hub.dart' show boundedOutput;
import 'posix_ffi.dart';
import 'protocol.dart';

/// Keeps the timers of scheduled projects and tells the user what a
/// scheduled run could not do.
abstract interface class ProjectScheduler {
  /// Writes (or rewrites) the timer of project [id] for the `OnCalendar`
  /// values [calendar] and enables it. Throws
  /// `ServiceError('project_schedule_unavailable', reason)`; a first install
  /// that failed leaves nothing behind, a failed rewrite puts the previous
  /// files back.
  Future<void> install(String id, List<String> calendar);

  /// Disables and removes the timer of [id], if Maprisma wrote it. Throws
  /// `ServiceError('project_schedule_unavailable', reason)` when the timer
  /// could not be stopped (its files then stay, so a later removal tries
  /// again) or its files or systemd's reload failed.
  Future<void> remove(String id);

  /// The project ids whose managed timer files exist. The unit folder is
  /// read one entry at a time (only names of ours are kept); a folder that
  /// cannot be read throws `ServiceError('project_schedule_unavailable')`
  /// instead of counting as "no timers".
  Future<Set<String>> installed();

  /// A desktop notification (best effort).
  void notify(String title, String body);
}

/// The first line of every unit file Maprisma writes for a schedule; a file
/// without it is never overwritten or removed.
const scheduleMarker = '# Managed by Maprisma: scheduled AI project.';

/// The second line: which store's project the unit belongs to. A unit of
/// another store (a test's, another data folder) is not this store's own.
const scheduleStoreLine = '# Maprisma store: ';

/// The tag of the store in [dataDirectory] for [scheduleStoreLine].
String scheduleStoreTag(String dataDirectory) => sha256
    .convert(utf8.encode(p.normalize(dataDirectory)))
    .toString()
    .substring(0, 16);

final _storeTag = RegExp(r'^[0-9a-f]{16}$');
final _projectId = RegExp(r'^[0-9a-f]{32}$');
final _calendarLine = RegExp(r'^[0-9A-Za-z*,:/~ -]{1,120}$');
final _unitName = RegExp(r'^maprisma-project-([0-9a-f]{32})\.(timer|service)$');

/// Variables the scheduled run gets as the app had them, so it finds the
/// same agents (PATH), the same store (XDG) and the same bundle.
const _pinned = [
  'PATH',
  'XDG_CONFIG_HOME',
  'XDG_DATA_HOME',
  'XDG_STATE_HOME',
  'XDG_CACHE_HOME',
  'MAPRISMA_DESKTOP',
  'MAPRISMA_FEATURE_BUNDLE_ROOT',
];

bool _hasControl(String text) => text.codeUnits.any((c) => c < 32 || c == 127);

/// One systemd argument: double-quoted, with `\`, `"`, `%` (specifiers) and
/// `$` (variable expansion) escaped. Control characters are refused.
String systemdWord(String word) {
  if (_hasControl(word)) throw ServiceError('project_schedule_unavailable');
  final escaped = word
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('%', '%%')
      .replaceAll(r'$', r'$$');
  return '"$escaped"';
}

/// One `Environment=` assignment, quoted (no variable expansion there).
String systemdAssignment(String name, String value) {
  if (_hasControl(value)) throw ServiceError('project_schedule_unavailable');
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('%', '%%');
  return '"$name=$escaped"';
}

String scheduleTimerName(String id) => 'maprisma-project-$id.timer';
String scheduleServiceName(String id) => 'maprisma-project-$id.service';

/// The service unit that starts the scheduled run of [id] with [command]
/// (`schedule-run <id>` is added as words of their own).
String scheduleServiceText(
  String id,
  List<String> command,
  Map<String, String> environment, {
  required String store,
}) {
  if (!_projectId.hasMatch(id) ||
      !_storeTag.hasMatch(store) ||
      command.isEmpty ||
      !p.isAbsolute(command.first)) {
    throw ServiceError('project_schedule_unavailable');
  }
  final pins = <String>[
    for (final name in _pinned)
      if ((environment[name] ?? '').isNotEmpty &&
          !_hasControl(environment[name]!))
        'Environment=${systemdAssignment(name, name == 'PATH' ? _absolutePath(environment[name]!) : environment[name]!)}',
    'Environment=${systemdAssignment('MAPRISMA_FEATURE_PROCESS', 'ai-project-center')}',
  ];
  return [
    scheduleMarker,
    '$scheduleStoreLine$store',
    '# Maprisma rewrites or removes this file; changes here are lost.',
    '[Unit]',
    'Description=Maprisma: scheduled run of an AI project ($id)',
    '',
    '[Service]',
    'Type=exec',
    ...pins,
    'ExecStart=${[...command, 'schedule-run', id].map(systemdWord).join(' ')}',
    'KillMode=mixed',
    'TimeoutStopSec=30',
    '',
  ].join('\n');
}

String _absolutePath(String value) =>
    value.split(':').where((part) => p.isAbsolute(part)).join(':');

/// The timer unit of [id] for [calendar].
String scheduleTimerText(
  String id,
  List<String> calendar, {
  required String store,
}) {
  if (!_projectId.hasMatch(id) ||
      !_storeTag.hasMatch(store) ||
      calendar.isEmpty ||
      calendar.any((line) => !_calendarLine.hasMatch(line))) {
    throw ServiceError('project_schedule_unavailable');
  }
  return [
    scheduleMarker,
    '$scheduleStoreLine$store',
    '# Maprisma rewrites or removes this file; changes here are lost.',
    '[Unit]',
    'Description=Maprisma: schedule of an AI project ($id)',
    '',
    '[Timer]',
    for (final line in calendar) 'OnCalendar=$line',
    'Persistent=true',
    'AccuracySec=1s',
    'Unit=${scheduleServiceName(id)}',
    '',
    '[Install]',
    'WantedBy=timers.target',
    '',
  ].join('\n');
}

typedef SystemctlRunner = Future<(bool, String)> Function(List<String> args);

/// systemd user timers in `$XDG_CONFIG_HOME/systemd/user`.
final class SystemdUserScheduler implements ProjectScheduler {
  SystemdUserScheduler({
    required this.unitDir,
    required this.environment,
    required this.store,
    List<String>? Function()? command,
    SystemctlRunner? systemctl,
    bool Function(String title, String body)? notifier,
    Posix? posix,
  }) : _command = command ?? projectScheduleCommand,
       _systemctl = systemctl,
       _notifier = notifier,
       _io = posix ?? Posix();

  /// For the account of [environment] (its HOME and XDG folders).
  factory SystemdUserScheduler.forEnvironment(Map<String, String> environment) {
    final identity = AppIdentity(environment: environment);
    return SystemdUserScheduler(
      unitDir: p.join(
        identity.root('XDG_CONFIG_HOME', '.config'),
        'systemd',
        'user',
      ),
      environment: environment,
      store: scheduleStoreTag(identity.dataDir),
    );
  }

  final String unitDir;

  /// [scheduleStoreTag] of the store whose projects these timers run.
  final String store;
  final Map<String, String> environment;
  final List<String>? Function() _command;
  final SystemctlRunner? _systemctl;
  final bool Function(String title, String body)? _notifier;
  final Posix _io;

  Future<(bool, String)> _run(List<String> args) async {
    final custom = _systemctl;
    if (custom != null) return custom(args);
    final program = whichIn('systemctl', environment['PATH']);
    if (program == null) return (false, 'no systemctl');
    final (out, ok) = await boundedOutput(
      [program, '--user', ...args],
      timeout: const Duration(seconds: 60),
      mergeStderr: true,
    );
    final text = utf8.decode(out, allowMalformed: true).trim();
    return (ok, text.length > 300 ? text.substring(0, 300) : text);
  }

  /// The file's text when it is a regular file Maprisma wrote, '' when
  /// there is none, null when something else is in the way.
  String? _managed(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return '';
    if (type != FileSystemEntityType.file) return null;
    final stat = _io.lstatOwn(path);
    if (stat == null || stat.uid != _io.uid || stat.size > 64 * 1024) {
      return null;
    }
    try {
      final text = utf8.decode(
        _io.readRegular(path, 64 * 1024),
        allowMalformed: true,
      );
      return text.startsWith('$scheduleMarker\n$scheduleStoreLine$store\n')
          ? text
          : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> install(String id, List<String> calendar) async {
    final command = _command();
    if (command == null || !_projectId.hasMatch(id)) {
      throw ServiceError('project_schedule_unavailable');
    }
    final timer = p.join(unitDir, scheduleTimerName(id));
    final service = p.join(unitDir, scheduleServiceName(id));
    final texts = {
      service: scheduleServiceText(id, command, environment, store: store),
      timer: scheduleTimerText(id, calendar, store: store),
    };
    final before = {for (final path in texts.keys) path: _managed(path)};
    if (before.values.any((text) => text == null)) {
      throw ServiceError('project_schedule_unavailable');
    }
    final fresh = before.values.every((text) => text!.isEmpty);
    final wants = p.join(unitDir, 'timers.target.wants', scheduleTimerName(id));
    final changed = texts.entries.where((e) => before[e.key] != e.value);
    if (changed.isEmpty &&
        FileSystemEntity.typeSync(wants, followLinks: false) ==
            FileSystemEntityType.link) {
      return;
    }
    final written = <String>[];
    var started = false;
    try {
      Directory(unitDir).createSync(recursive: true);
      for (final entry in changed) {
        _io.replaceFile(entry.key, utf8.encode(entry.value), 0x1a4);
        written.add(entry.key);
      }
      for (final args in [
        ['daemon-reload'],
        ['enable', scheduleTimerName(id)],
        ['restart', scheduleTimerName(id)],
      ]) {
        started = args.first == 'restart';
        final (ok, said) = await _run(args);
        if (!ok) {
          throw ServiceError(
            'project_schedule_unavailable',
            _said('systemctl ${args.first}', said),
          );
        }
      }
    } on Object catch (error) {
      final reason = error is ServiceError && error.reason != null
          ? error.reason
          : '$error';
      if (fresh && started) {
        // It may run: stopped first, or its files stay for the next
        // reconciliation, which removes it.
        try {
          await remove(id);
        } on Object {
          // Kept (see above).
        }
      } else if (fresh) {
        // Never started: nothing of it may stay (an enable that went half
        // way leaves its link; disable takes it back).
        try {
          await _run(['disable', scheduleTimerName(id)]);
        } on Object {
          // Its files go all the same.
        }
        for (final path in written) {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Gone already.
          }
        }
        try {
          await _run(['daemon-reload']);
        } on Object {
          // Nothing of it is left to load.
        }
      } else if (written.isNotEmpty) {
        // A rewrite that failed: the previous timer as it was, so systemd
        // and the store's schedule do not drift apart (best effort; the
        // next reconciliation writes it again).
        try {
          for (final path in written) {
            final text = before[path]!;
            if (text.isEmpty) {
              File(path).deleteSync();
            } else {
              _io.replaceFile(path, utf8.encode(text), 0x1a4);
            }
          }
          await _run(['daemon-reload']);
          await _run(['restart', scheduleTimerName(id)]);
        } on Object {
          // See above.
        }
      }
      throw ServiceError('project_schedule_unavailable', reason);
    }
  }

  static String _said(String what, String said) =>
      said.isEmpty ? '$what failed' : '$what failed: $said';

  @override
  Future<void> remove(String id) async {
    if (!_projectId.hasMatch(id)) return;
    final paths = [
      p.join(unitDir, scheduleTimerName(id)),
      p.join(unitDir, scheduleServiceName(id)),
    ];
    final managed = [
      for (final path in paths)
        if (_managed(path) case final text? when text.isNotEmpty) path,
    ];
    if (managed.isEmpty) return;
    if (managed.contains(paths.first)) {
      // The timer only: a scheduled run that works now goes on (its
      // service stays loaded until it ends). A timer not known to be
      // stopped keeps its files: removed, systemd would keep running it
      // with nothing left that says it is Maprisma's.
      final (ok, said) = await _run([
        'disable',
        '--now',
        scheduleTimerName(id),
      ]);
      if (!ok) {
        throw ServiceError(
          'project_schedule_unavailable',
          _said('systemctl disable --now', said),
        );
      }
    }
    final left = <String>[];
    for (final path in managed) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          left.add(p.basename(path));
        }
      }
    }
    final (ok, said) = await _run(['daemon-reload']);
    if (left.isNotEmpty) {
      throw ServiceError(
        'project_schedule_unavailable',
        '${left.join(', ')} could not be removed',
      );
    }
    if (!ok) {
      throw ServiceError(
        'project_schedule_unavailable',
        _said('systemctl daemon-reload', said),
      );
    }
  }

  @override
  Future<Set<String>> installed() async {
    final ids = <String>{};
    try {
      // One entry at a time: a large systemd/user folder costs time, never
      // memory, and no unit of ours is left out.
      await for (final entry in Directory(unitDir).list(followLinks: false)) {
        final match = _unitName.firstMatch(p.basename(entry.path));
        if (match == null) continue;
        final text = _managed(entry.path);
        if (text != null && text.isNotEmpty) ids.add(match[1]!);
      }
    } on PathNotFoundException {
      // No unit folder yet: no timers.
    } on FileSystemException catch (error) {
      throw ServiceError(
        'project_schedule_unavailable',
        'the unit folder cannot be read: ${error.osError?.message ?? error.message}',
      );
    }
    return ids;
  }

  @override
  void notify(String title, String body) {
    final custom = _notifier;
    if (custom != null) {
      custom(title, body);
      return;
    }
    final program = whichIn('notify-send', environment['PATH']);
    if (program == null) return;
    unawaited(
      boundedOutput(
        [program, '--app-name=Maprisma', '--', title, body],
        timeout: const Duration(seconds: 10),
      ).then<void>((_) {}, onError: (_) {}),
    );
  }
}
