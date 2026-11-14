// Task 073: what the release installer and Maprisma Control need from a running Maprisma.
//
// - The instance lock: the GUI holds a shared flock(2) on `<bundle>/data/instance.lock` for its whole
//   life (opened read-only, close-on-exec, so it works in a root-owned /opt install and no agent or
//   terminal started from Maprisma inherits it). The installer takes it exclusively for its whole
//   transaction: it refuses while any user's Maprisma of that install runs, and a Maprisma started
//   during an install finds the lock taken and does not start.
// - The launch record `$XDG_STATE_HOME/maprisma/launch.json` (0600): how this Maprisma was started, so
//   Maprisma Control can start it again when it is neither in ~/.local/bin, on PATH nor /usr/bin (an
//   AppImage, an /opt install). User launch configuration only: Control checks it before use.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'posix_ffi.dart';

enum InstanceLockState {
  /// This process holds the shared lock until it exits.
  held,

  /// An install or uninstall holds it: this Maprisma must not start.
  busy,

  /// No lock file (a development build, an older bundle): nothing to coordinate.
  none,
}

/// Takes the shared instance lock of the bundle [bundleDir] (the folder of the executable). The
/// descriptor stays open (and the lock held) for the rest of the process.
InstanceLockState takeInstanceLock(String bundleDir, {Posix? posix}) {
  final path = p.join(bundleDir, 'data', 'instance.lock');
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return InstanceLockState.none;
  }
  final px = posix ?? Posix();
  final int fd;
  try {
    fd = px.openAt(-100, path, 0 /* O_RDONLY */);
  } on OSError {
    return InstanceLockState.none;
  }
  if (px.tryFlock(fd, shared: true)) {
    _held.add(fd); // kept open on purpose
    return InstanceLockState.held;
  }
  px.close(fd);
  return InstanceLockState.busy;
}

final _held = <int>[];

/// The launch record's mode and path for this process, or null when there is nothing worth
/// recording (no absolute executable).
({String exec, String mode})? launchRecordFor(
  Map<String, String> env,
  String executable,
) {
  final appImage = env['APPIMAGE'] ?? '';
  if (appImage.isNotEmpty &&
      p.isAbsolute(appImage) &&
      FileSystemEntity.typeSync(appImage, followLinks: false) ==
          FileSystemEntityType.file) {
    final extracted =
        env['APPIMAGE_EXTRACT_AND_RUN'] == '1' ||
        (env['APPDIR'] ?? '').contains('/appimage_extracted_');
    return (exec: appImage, mode: extracted ? 'appimage-extract' : 'appimage');
  }
  if (!p.isAbsolute(executable)) return null;
  return (exec: executable, mode: 'bundle');
}

/// Writes `launch.json` atomically as a 0600 file in `$XDG_STATE_HOME/maprisma` (folder 0700 when it
/// is made here). Errors are swallowed: Control then falls back to its other places.
void writeLaunchRecord(
  Map<String, String> env,
  String executable, {
  Posix? posix,
}) {
  final record = launchRecordFor(env, executable);
  final home = env['HOME'] ?? '';
  if (record == null || !p.isAbsolute(home)) return;
  final stateHome = env['XDG_STATE_HOME'] ?? '';
  final dir = p.join(
    p.isAbsolute(stateHome) ? stateHome : p.join(home, '.local/state'),
    'maprisma',
  );
  final px = posix ?? Posix();
  try {
    Directory(p.dirname(dir)).createSync(recursive: true);
    if (!Directory(dir).existsSync()) px.mkdirAt(-100, dir, 0x1c0 /* 0700 */);
    final target = p.join(dir, 'launch.json');
    final text = '${jsonEncode({'exec': record.exec, 'mode': record.mode})}\n';
    final existing = File(target);
    if (FileSystemEntity.typeSync(target, followLinks: false) ==
            FileSystemEntityType.file &&
        existing.readAsStringSync() == text) {
      return;
    }
    final temp = p.join(dir, '.launch.json.$pid');
    final fd = px.openAt(
      -100,
      temp,
      0x1 | 0x40 | 0x80 | 0x20000 /* WRONLY|CREAT|EXCL|NOFOLLOW */,
      0x180,
    );
    try {
      px.write(fd, utf8.encode(text));
      px.chmod(fd, 0x180); // 0600 whatever the umask
      px.sync(fd);
    } finally {
      px.close(fd);
    }
    File(temp).renameSync(target);
  } on Object {
    // best effort: Control falls back to ~/.local/bin, PATH and /usr/bin
  }
}
