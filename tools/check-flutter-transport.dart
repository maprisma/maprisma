// Runs with the Dart SDK alone, independently of Flutter package downloads.
import 'dart:io';

import '../flutter_app/lib/backend.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'asterism-transport-',
  );
  Backend? backend;
  try {
    await File('${directory.path}/flutter_backend.py').writeAsString(r'''
import json, sys
for line in sys.stdin:
    req = json.loads(line)
    if req['method'] == 'malformed':
        print(json.dumps({'id': req['id'], 'result': []}), flush=True)
    elif req['method'] == 'null-error':
        print(json.dumps({'id': None, 'error': {'code': 'invalid_request'}}), flush=True)
        print(json.dumps({'id': req['id'], 'result': {'ok': True}}), flush=True)
    elif req['method'] == 'error':
        print(json.dumps({'id': req['id'], 'error': {'code': 'invalid_request'}}), flush=True)
    else:
        print(json.dumps({'id': req['id'], 'result': {'echo': req['params']}}), flush=True)
''');
    backend = await Backend.start(directory.path);
    final answers = await Future.wait([
      backend.call('echo', {
        'path': '/project with spaces; literal',
        'label': '世界',
      }),
      backend.call('echo', {'order': 2}),
    ]);
    check(answers[0]['echo']['label'] == '世界', 'Unicode frame was corrupted');
    check(
      answers[0]['echo']['path'] == '/project with spaces; literal',
      'Path frame changed',
    );
    check(answers[1]['echo']['order'] == 2, 'Request correlation failed');
    check(
      (await backend.call('null-error'))['ok'] == true,
      'Null-id errors broke the connection',
    );
    bool rejected = false;
    try {
      await backend.call('error');
    } on BackendError catch (error) {
      rejected = error.code == 'invalid_request';
    }
    check(rejected, 'Service error code was not delivered');
    check(
      (await backend.call('echo', {'after': true}))['echo']['after'] == true,
      'A request error broke the connection',
    );
    rejected = false;
    try {
      await backend.call('malformed').timeout(const Duration(seconds: 2));
    } on FormatException {
      rejected = true;
    }
    check(rejected, 'Malformed reply did not fail promptly');
    backend.dispose();
    backend = null;
    stdout.writeln('Dart transport checks passed.');
  } finally {
    backend?.dispose();
    await directory.delete(recursive: true);
  }
}
