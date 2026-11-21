import 'package:maprisma_core/maprisma_core.dart' show Posix;
import 'dart:io';
import 'package:maprisma/backend.dart';
import 'package:maprisma/isolate_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'isolate runs persisted settings and bounded protocol outside UI',
    () async {
      final home = Directory.systemTemp.createTempSync('maprisma-isolate-');
      final transport = await IsolateTransport.start(
        environment: {'HOME': home.path, 'MAPRISMA_DESKTOP': 'generic'},
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
    'the core answers every route itself; an unknown one is refused',
    () async {
      final home = Directory.systemTemp.createTempSync('maprisma-backend-');
      final backend = Backend.fromTransport(
        await IsolateTransport.start(environment: {'HOME': home.path}),
      );
      try {
        await expectLater(
          backend.call('settings.update', {
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
        await expectLater(
          backend.call('nothing.unported', {}),
          throwsA(
            isA<BackendError>().having((e) => e.code, 'code', 'unported_route'),
          ),
        );
        await expectLater(
          backend.call('tasks.status', {'task': 'core-0000'}),
          throwsA(
            isA<BackendError>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        expect(home.listSync(), isEmpty);
      } finally {
        await backend.shutdown();
        home.deleteSync(recursive: true);
      }
    },
  );
  test(
    'a Devel build marks its core, so it never manages the user service',
    () {
      expect(coreEnvironment(devel: false, environment: {'HOME': '/h'}), {
        'HOME': '/h',
      });
      expect(coreEnvironment(devel: true, environment: {'HOME': '/h'}), {
        'HOME': '/h',
        'MAPRISMA_FLUTTER_DEVEL': '1',
      });
    },
  );
  test(
    'isolate initialization failure is reported without a hanging handshake',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'maprisma-isolate-failure-',
      );
      try {
        final outside = Directory('${home.path}/outside/maprisma')
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

  test(
    'disposing an embedded core releases the AI Project Center store lock',
    () async {
      final home = Directory.systemTemp.createTempSync('maprisma-isolate-');
      final environment = {'HOME': home.path, 'MAPRISMA_DESKTOP': 'generic'};
      Future<Map<String, dynamic>> list(IsolateTransport transport) =>
          transport.call('features.call', {
            'plugin': 'ai-project-center',
            'operation': 'list',
            'params': <String, dynamic>{},
          });
      try {
        final first = await IsolateTransport.start(environment: environment);
        expect((await list(first))['projects'], isEmpty);
        first.dispose();
        IsolateTransport? second;
        Object? failure;
        for (var attempt = 0; attempt < 20; attempt++) {
          second = await IsolateTransport.start(environment: environment);
          try {
            await list(second);
            failure = null;
            break;
          } on BackendError catch (error) {
            failure = error.code;
            second.dispose();
            second = null;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(failure, isNull);
        await second?.shutdown();
      } finally {
        home.deleteSync(recursive: true);
      }
    },
  );

  test('feature shutdown may take longer than the core\'s worst case', () {
    // Project Center first (start 10 s + @shutdown 30 s + exit 10 s), then
    // the other features together (the same again).
    expect(
      callTimeout('features.shutdown'),
      greaterThan(const Duration(seconds: 100)),
    );
    expect(callTimeout('features.summary'), const Duration(seconds: 60));
  });
}
