import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// F9: a picture of the app's own window, in ~/Pictures/Maprisma, while the
/// setting screenshot_key is on (default).
final class WindowShots {
  WindowShots(this.folder);
  final String folder;

  static WindowShots fromEnvironment(Map<String, String> environment) =>
      WindowShots('${environment['HOME'] ?? ''}/Pictures/Maprisma');

  /// maprisma-2026-11-01-08-26-31.png, then -2 within the same second.
  String pathFor(DateTime time) {
    String two(int n) => '$n'.padLeft(2, '0');
    final stem =
        'maprisma-${time.year}-${two(time.month)}-${two(time.day)}'
        '-${two(time.hour)}-${two(time.minute)}-${two(time.second)}';
    var path = '$folder/$stem.png';
    for (var n = 2; File(path).existsSync(); n++) {
      path = '$folder/$stem-$n.png';
    }
    return path;
  }

  Future<String> save(Uint8List png, DateTime time) async {
    await Directory(folder).create(recursive: true);
    final path = pathFor(time);
    await File(path).writeAsBytes(png, flush: true);
    return path;
  }
}

/// F9 in a recorded manual test (tools/test-session.sh): the picture and a
/// note, next to the protocol, whatever the setting says. Only while
/// MAPRISMA_RECORD_PROTOCOL is set.
final class TestShots {
  TestShots(this.protocol);
  final String protocol;

  static TestShots? fromEnvironment(Map<String, String> environment) {
    final path = environment['MAPRISMA_RECORD_PROTOCOL'] ?? '';
    return path.isEmpty ? null : TestShots(path);
  }

  String get _run => File(protocol).parent.path;
  String get folder => '$_run/shots';

  /// shots/08-26-31.png, then 08-26-31-2.png within the same second.
  String pathFor(DateTime time) {
    String two(int n) => '$n'.padLeft(2, '0');
    final stem = '${two(time.hour)}-${two(time.minute)}-${two(time.second)}';
    var path = '$folder/$stem.png';
    for (var n = 2; File(path).existsSync(); n++) {
      path = '$folder/$stem-$n.png';
    }
    return path;
  }

  Future<String> save(Uint8List png, DateTime time) async {
    await Directory(folder).create(recursive: true);
    final path = pathFor(time);
    await File(path).writeAsBytes(png, flush: true);
    return path;
  }

  /// One line in the protocol, at the moment the picture was taken.
  Future<void> record(String path, String note, DateTime time) async {
    final line = {
      'time': time.toIso8601String(),
      'method': 'test.shot',
      'params': {'file': path.substring(_run.length + 1), 'note': note},
      'result': {},
    };
    await File(protocol).writeAsString(
      '${jsonEncode(line)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
