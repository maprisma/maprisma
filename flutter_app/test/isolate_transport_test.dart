import 'package:asterism_core/asterism_core.dart' show Posix;
import 'dart:io';
import 'package:asterism/backend.dart';
import 'package:asterism/isolate_transport.dart';
import 'package:asterism/service_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'isolate runs persisted settings and bounded protocol outside UI',
    () async {
      final home = Directory.systemTemp.createTempSync('asterism-isolate-');
      final transport = await IsolateTransport.start(
        environment: {'HOME': home.path, 'ASTERISM_DESKTOP': 'generic'},
      );
      try {
        expect((await transport.call('settings.get'))['map_light_fps'], 20);
        await transport.call('settings.update', {
          'values': {'map_light_fps': 30},
        });
        expect((await transport.call('settings.get'))['map_light_fps'], 30);
        await expectLater(
          transport.call('settings.update', {
            'values': {'map_light_fps': true},
          }),
          throwsA(
            isA<BackendError>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        await expectLater(
          transport.call('i18n.lookup', {'text': 'x' * 65536}),
          throwsA(
            isA<BackendError>().having(
              (e) => e.code,
              'code',
              'request_too_large',
            ),
          ),
        );
        expect(transport.isConnected, true);
      } finally {
        await transport.shutdown();
        home.deleteSync(recursive: true);
      }
      await expectLater(transport.call('settings.get'), throwsStateError);
    },
  );
  test(
    'router never starts fallback on ported error; non-Devel refuses unported',
    () async {
      final home = Directory.systemTemp.createTempSync('asterism-router-');
      final router = ServiceRouter(
        await IsolateTransport.start(environment: {'HOME': home.path}),
        root: home.path,
      );
      try {
        await expectLater(
          router.call('settings.update', {
            'values': {'map_light_fps': 99},
          }),
          throwsA(
            isA<BackendError>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        if (!develPythonFallback) {
          await expectLater(
            router.call('nothing.unported', {}),
            throwsA(
              isA<BackendError>().having(
                (e) => e.code,
                'code',
                'unported_route',
              ),
            ),
          );
        }
        // Handles go to the side that made them: a core handle to the core
        // (unknown here), any other one only to the Devel reference.
        await expectLater(
          router.call('tasks.status', {'task': 'core-0000'}),
          throwsA(
            isA<BackendError>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        if (!develPythonFallback) {
          await expectLater(
            router.call('connections.undo', {'undo': 'a1b2c3'}),
            throwsA(
              isA<BackendError>().having(
                (e) => e.code,
                'code',
                'unported_route',
              ),
            ),
          );
        }
        expect(home.listSync(), isEmpty);
      } finally {
        await router.shutdown();
        home.deleteSync(recursive: true);
      }
    },
  );
  test(
    'isolate initialization failure is reported without a hanging handshake',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'asterism-isolate-failure-',
      );
      try {
        final outside = Directory('${home.path}/outside/asterism')
          ..createSync(recursive: true);
        File(
          '${outside.path}/settings.json',
        ).writeAsStringSync('{"animate_lines":false}');
        Link('${home.path}/.config').createSync('${home.path}/outside');
        final unsafe = Posix();
        final fd = unsafe.openAt(-100, '${home.path}/outside', Posix.directory);
        try {
          unsafe.chmod(fd, 0x1ff);
        } finally {
          unsafe.close(fd);
        }
        await expectLater(
          IsolateTransport.start(environment: {'HOME': home.path}),
          throwsStateError,
        );
      } finally {
        home.deleteSync(recursive: true);
      }
    },
  );
  test('Devel router starts Python only for unported routes', () async {
    if (!develPythonFallback) return;
    final home = Directory.systemTemp.createTempSync('asterism-fallback-');
    final script = File('${home.path}/flutter_backend.py')
      ..writeAsStringSync('''import json,sys
invalidations=0
for line in sys.stdin:
 q=json.loads(line)
 if q['method']=='app.settings_changed': invalidations+=1
 print(json.dumps({'id':q['id'],'result':{'reference':True,'invalidations':invalidations}}),flush=True)
''');
    final router = ServiceRouter(
      await IsolateTransport.start(environment: {'HOME': home.path}),
      root: home.path,
    );
    try {
      expect((await router.call('settings.get'))['map_light_fps'], 20);
      expect(await router.call('app.snapshot'), {
        'reference': true,
        'invalidations': 0,
      });
      expect(
        (await router.call('settings.update', {
          'values': {'language': 'de'},
        }))['language'],
        'de',
      );
      expect(
        (await router.call('i18n.lookup', {'text': 'Settings'}))['language'],
        'de',
      );
      expect(await router.call('app.snapshot'), {
        'reference': true,
        'invalidations': 1,
      });
      expect(script.existsSync(), true);
    } finally {
      await router.shutdown();
      home.deleteSync(recursive: true);
    }
  });
}
