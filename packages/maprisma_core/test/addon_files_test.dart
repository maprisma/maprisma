import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/src/addon_store.dart';
import 'package:maprisma_core/src/addons.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:test/test.dart';

/// Uwe's signed add-ons, next to this checkout (skipped without them).
final dist = Directory(
  '${Directory.current.path}/../../../maprisma-addons/dist',
);

/// The version Uwe signed them with (agent-goose/addon.json beside dist).
String signedVersion() {
  final meta = File('${dist.parent.path}/agent-goose/addon.json');
  return meta.existsSync()
      ? (jsonDecode(meta.readAsStringSync()) as Map)['version'] as String
      : '';
}

void main() {
  final version = signedVersion();
  final goose = File('${dist.path}/agent-goose-$version.zip');
  final skip = goose.existsSync() ? false : 'maprisma-addons/dist not found';

  test('an add-on file is reviewed, then installed from the same bytes', () {
    final temp = Directory.systemTemp.createTempSync('maprisma-addon-file-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final user = '${temp.path}/addons';
    final store = AddonStore(Posix(), user, temp.path, AddonVerifier(Posix()));
    final zip = goose.copySync('${temp.path}/goose.zip');
    var n = 0;
    final files = AddonFileImports(() => 'token${n++}');
    final preview = files.preview(zip.path, store, [user]);
    expect(preview['id'], 'agent-goose');
    expect(preview['version'], version);
    expect(preview['kind'], 'agent');
    expect(preview['action'], 'install');
    expect(
      Directory(user).existsSync(),
      isFalse,
    ); // nothing installed by the review
    final request = files.apply(preview['preview']);
    expect(() => files.apply(preview['preview']), throwsA(isA<InstallError>()));
    final result = installAddonFile(
      Map<String, dynamic>.from(jsonDecode(utf8.decode(request)) as Map),
      store,
    );
    expect(result, {'ok': true, 'id': 'agent-goose', 'version': version});
    expect(store.installed([user])['agent-goose']?.version, version);
    // Reviewed again now, it would replace the installed copy.
    expect(files.preview(zip.path, store, [user])['action'], 'update');
  }, skip: skip);

  test('a changed, linked, foreign or wrong file is refused', () {
    final temp = Directory.systemTemp.createTempSync('maprisma-addon-file-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final user = '${temp.path}/addons';
    final store = AddonStore(Posix(), user, temp.path, AddonVerifier(Posix()));
    final files = AddonFileImports(() => 'token');
    final zip = goose.copySync('${temp.path}/goose.zip');
    // Changed after the review: the worker reads it again and refuses it.
    final request = files.apply(
      files.preview(zip.path, store, [user])['preview'],
    );
    zip.writeAsBytesSync([...zip.readAsBytesSync(), 0]);
    expect(
      () => installAddonFile(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(request)) as Map),
        store,
      ),
      throwsA(isA<InstallError>()),
    );
    // A link at the path, a non-zip name, garbage, too large.
    Link('${temp.path}/link.zip').createSync(goose.path);
    expect(
      () => files.preview('${temp.path}/link.zip', store, [user]),
      throwsA(isA<InstallError>()),
    );
    expect(
      () => files.preview(goose.path.replaceAll('.zip', '.tar'), store, [user]),
      throwsA(isA<InstallError>()),
    );
    final garbage = File('${temp.path}/garbage.zip')
      ..writeAsStringSync('not a zip');
    expect(
      () => files.preview(garbage.path, store, [user]),
      throwsA(isA<InstallError>()),
    );
    final large = File('${temp.path}/large.zip')
      ..writeAsBytesSync(List.filled(maxZip + 1, 0));
    expect(
      () => files.preview(large.path, store, [user]),
      throwsA(isA<InstallError>()),
    );
    expect(Directory(user).existsSync(), isFalse);
  }, skip: skip);
}
