import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'identity.dart';
import 'posix_ffi.dart';

abstract interface class Desktop {
  String get name;
  String? get themeDir;
  Map<String, String> themeColors();
}

Desktop detectDesktop(AppIdentity identity, Posix posix) {
  final env = identity.environment;
  final wanted = env['ASTERISM_DESKTOP'];
  final omarchy =
      wanted == 'omarchy' ||
      wanted != 'generic' &&
          Directory(
            env['OMARCHY_PATH']?.isNotEmpty == true
                ? env['OMARCHY_PATH']!
                : '/usr/share/omarchy',
          ).existsSync();
  return omarchy ? OmarchyDesktop(identity, posix) : GenericDesktop();
}

final class GenericDesktop implements Desktop {
  @override
  String get name => 'generic';
  @override
  String? get themeDir => null;
  // app.theme is deliberately empty on generic desktops, as in Python.
  // Flutter follows platform brightness there; no GTK import or gsettings call.
  @override
  Map<String, String> themeColors() => {};
}

final class OmarchyDesktop implements Desktop {
  OmarchyDesktop(this.identity, this.posix);
  final AppIdentity identity;
  final Posix posix;
  @override
  String get name => 'omarchy';
  @override
  String get themeDir =>
      p.join(identity.home, '.local/state/omarchy/current/theme');
  @override
  Map<String, String> themeColors() {
    try {
      // The theme's current directory is intentionally a managed symlink.
      final bytes = posix.readRegular(
        p.join(themeDir, 'colors.toml'),
        256 * 1024,
        follow: true,
      );
      final data = TomlDocument.parse(
        utf8.decode(bytes, allowMalformed: true),
      ).toMap();
      return {
        for (final e in data.entries)
          if (e.value is String &&
              RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(e.value))
            e.key: e.value as String,
      };
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    } on TomlException {
      return {};
    }
  }
}
