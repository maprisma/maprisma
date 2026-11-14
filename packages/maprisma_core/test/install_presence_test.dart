// Task 073: the instance lock the release installer waits for, and the launch record for Control.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/maprisma_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('presence-'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('instance lock', () {
    test('no lock file: nothing to coordinate', () {
      expect(takeInstanceLock(dir.path), InstanceLockState.none);
    });

    test(
      'shared with other Maprismas, refused while an install holds it exclusively',
      () {
        File('${dir.path}/data/instance.lock').createSync(recursive: true);
        final px = Posix();
        expect(takeInstanceLock(dir.path), InstanceLockState.held);
        expect(
          takeInstanceLock(dir.path),
          InstanceLockState.held,
        ); // a second user's Maprisma
        // the installer: exclusive is refused while a Maprisma runs
        final installer = px.openAt(-100, '${dir.path}/data/instance.lock', 0);
        expect(px.tryFlock(installer, shared: false), isFalse);
        px.close(installer);
      },
    );

    test('a Maprisma started during an install is busy', () {
      File('${dir.path}/data/instance.lock').createSync(recursive: true);
      final px = Posix();
      final installer = px.openAt(-100, '${dir.path}/data/instance.lock', 0);
      expect(px.tryFlock(installer, shared: false), isTrue);
      expect(takeInstanceLock(dir.path), InstanceLockState.busy);
      px.close(installer);
    });

    test('works on a read-only lock file (a root-owned /opt install)', () {
      final f = File('${dir.path}/data/instance.lock')
        ..createSync(recursive: true);
      Process.runSync('chmod', ['0444', f.path]);
      expect(takeInstanceLock(dir.path), InstanceLockState.held);
    });
  });

  group('launch record', () {
    test('bundle, AppImage and AppImage extracted', () {
      expect(launchRecordFor({}, '/opt/maprisma/maprisma'), (
        exec: '/opt/maprisma/maprisma',
        mode: 'bundle',
      ));
      expect(launchRecordFor({}, 'maprisma'), isNull);
      final image = File('${dir.path}/Maprisma.AppImage')
        ..writeAsStringSync('x');
      expect(
        launchRecordFor({
          'APPIMAGE': image.path,
        }, '/tmp/.mount_x/usr/lib/maprisma/maprisma'),
        (exec: image.path, mode: 'appimage'),
      );
      expect(
        launchRecordFor({
          'APPIMAGE': image.path,
          'APPIMAGE_EXTRACT_AND_RUN': '1',
        }, '/x'),
        (exec: image.path, mode: 'appimage-extract'),
      );
      expect(
        launchRecordFor({
          'APPIMAGE': image.path,
          'APPDIR': '/tmp/appimage_extracted_ab12',
        }, '/x'),
        (exec: image.path, mode: 'appimage-extract'),
      );
      // an APPIMAGE that is no file (or relative) is not trusted
      expect(
        launchRecordFor({
          'APPIMAGE': '${dir.path}/gone',
        }, '/opt/m/maprisma')!.mode,
        'bundle',
      );
      expect(
        launchRecordFor({'APPIMAGE': 'rel/x'}, '/opt/m/maprisma')!.mode,
        'bundle',
      );
    });

    test(
      'written as a private file in XDG_STATE_HOME, rewritten only on change',
      () {
        final env = {'HOME': dir.path, 'XDG_STATE_HOME': '${dir.path}/state'};
        writeLaunchRecord(env, '/opt/maprisma/maprisma');
        final f = File('${dir.path}/state/maprisma/launch.json');
        expect(jsonDecode(f.readAsStringSync()), {
          'exec': '/opt/maprisma/maprisma',
          'mode': 'bundle',
        });
        expect(f.statSync().mode & 0x1ff, 0x180);
        expect(
          Directory('${dir.path}/state/maprisma').statSync().mode & 0x1ff,
          0x1c0,
        );
        final before = f.statSync().modified;
        writeLaunchRecord(env, '/opt/maprisma/maprisma');
        expect(f.statSync().modified, before);
        writeLaunchRecord({
          'HOME': dir.path,
        }, '/home/u/.local/lib/maprisma/maprisma');
        expect(
          File('${dir.path}/.local/state/maprisma/launch.json').existsSync(),
          isTrue,
        );
        expect(
          dir
              .listSync(recursive: true)
              .where((e) => e.path.contains('.launch.json.')),
          isEmpty,
        );
      },
    );

    test('loose modes are made private; a linked folder is never written', () {
      final env = {'HOME': dir.path, 'XDG_STATE_HOME': '${dir.path}/state'};
      writeLaunchRecord(env, '/opt/m/maprisma');
      final f = File('${dir.path}/state/maprisma/launch.json');
      Process.runSync('chmod', ['0666', f.path]);
      Process.runSync('chmod', ['0777', '${dir.path}/state/maprisma']);
      writeLaunchRecord(
        env,
        '/opt/m/maprisma',
      ); // same text: still made private
      expect(f.statSync().mode & 0x1ff, 0x180);
      expect(
        Directory('${dir.path}/state/maprisma').statSync().mode & 0x1ff,
        0x1c0,
      );
      final elsewhere = Directory('${dir.path}/elsewhere')..createSync();
      Directory('${dir.path}/state2').createSync();
      Link('${dir.path}/state2/maprisma').createSync(elsewhere.path);
      writeLaunchRecord({
        'HOME': dir.path,
        'XDG_STATE_HOME': '${dir.path}/state2',
      }, '/opt/m/maprisma');
      expect(elsewhere.listSync(), isEmpty);
    });

    test(
      'a symlink in place of the record is replaced, never written through',
      () {
        final target = File('${dir.path}/elsewhere')..writeAsStringSync('keep');
        Directory('${dir.path}/state/maprisma').createSync(recursive: true);
        Link('${dir.path}/state/maprisma/launch.json').createSync(target.path);
        writeLaunchRecord({
          'HOME': dir.path,
          'XDG_STATE_HOME': '${dir.path}/state',
        }, '/opt/m/maprisma');
        expect(target.readAsStringSync(), 'keep');
        expect(
          FileSystemEntity.isLinkSync('${dir.path}/state/maprisma/launch.json'),
          isFalse,
        );
      },
    );
  });
}
