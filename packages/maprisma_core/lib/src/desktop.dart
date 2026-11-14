import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'desktop_palette.dart';
import 'identity.dart';
import 'posix_ffi.dart';

abstract interface class Desktop {
  String get name;
  String? get themeDir;
  Map<String, String> themeColors();

  /// The desktop's interface and monospace font families, `{ui, mono}`
  /// (desktop_palette.desktopFonts), on every desktop.
  Map<String, String> fonts();

  /// A program in the user's terminal, a window of its own.
  bool openTerminal(List<String> argv, String cwd);

  /// Fixed commands one after the other while each succeeds, in one terminal
  /// window that waits at the end (run_steps_in_terminal).
  bool runStepsInTerminal(List<List<String>> steps, String prompt);
}

/// shlex.quote / shlex.join.
String shellQuote(String word) {
  if (word.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(word)) return word;
  return "'${word.replaceAll("'", "'\"'\"'")}'";
}

String shellJoin(List<String> words) => words.map(shellQuote).join(' ');

/// shutil.which over a PATH.
String? whichIn(String program, String? path) {
  for (final folder in (path ?? '').split(':')) {
    if (folder.isEmpty) continue;
    final candidate = p.join(folder, program);
    try {
      final st = File(candidate).statSync();
      if (st.type == FileSystemEntityType.file && st.mode & 0x49 != 0) {
        return candidate;
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// GTK's interface and monospace fonts from `gsettings get
/// org.gnome.desktop.interface font-name / monospace-font-name` (without
/// the size), asked at most every 30 s; meanwhile the last answer stands.
/// Without gsettings (or `timeout`) on [env]'s PATH: none.
final class GtkFonts {
  GtkFonts(this.env, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final Map<String, String> env;
  final DateTime Function() _clock;
  DateTime? _read;
  (String?, String?) _value = (null, null);

  (String?, String?) read() {
    final now = _clock();
    if (_read != null && now.difference(_read!).abs().inSeconds < 30) {
      return _value;
    }
    _read = now;
    final path = env['PATH'];
    final gsettings = whichIn('gsettings', path);
    final timeout = whichIn('timeout', path);
    if (gsettings == null || timeout == null) return _value = (null, null);
    String? get(String key) {
      try {
        final r = Process.runSync(
          timeout,
          ['3', gsettings, 'get', 'org.gnome.desktop.interface', key],
          environment: env,
          includeParentEnvironment: false,
          stdoutEncoding: utf8,
        );
        final out = r.exitCode == 0 ? (r.stdout as String).trim() : '';
        return out.length > 2 && out.startsWith("'") && out.endsWith("'")
            ? pangoFamily(out.substring(1, out.length - 1))
            : null;
      } on ProcessException {
        return null;
      }
    }

    return _value = (get('font-name'), get('monospace-font-name'));
  }
}

/// Started in a session of its own; a launcher found on PATH that then fails
/// to start is not waited for (the call stays synchronous).
bool _detached(List<String> argv, String cwd) {
  unawaited(
    Process.start(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: cwd,
      mode: ProcessStartMode.detached,
    ).then((_) {}, onError: (_) {}),
  );
  return true;
}

/// desktop.install_command: the command that installs vte4 or
/// xdg-terminal-exec here ('' when not known).
String installCommand(String desktop, String package, String? searchPath) {
  if (desktop == 'omarchy') {
    return const ['vte4', 'xdg-terminal-exec'].contains(package)
        ? 'sudo pacman -S $package'
        : '';
  }
  const packages = {
    'vte4': {
      'apt': 'gir1.2-vte-3.91',
      'dnf': 'vte291-gtk4',
      'zypper': 'typelib-1_0-Vte-3_91',
      'pacman': 'vte4',
    },
    'xdg-terminal-exec': {'pacman': 'xdg-terminal-exec'},
  };
  const managers = [
    ('apt', 'sudo apt install {0}'),
    ('dnf', 'sudo dnf install {0}'),
    ('zypper', 'sudo zypper install {0}'),
    ('pacman', 'sudo pacman -S {0}'),
  ];
  final manager = managers
      .where((m) => whichIn(m.$1, searchPath) != null)
      .firstOrNull;
  final name = manager == null ? null : packages[package]?[manager.$1];
  return name == null ? '' : manager!.$2.replaceAll('{0}', name);
}

/// A document opened in the desktop's default viewer (xdg-open, a process
/// of its own; no shell, no command line built from text). False when there
/// is no xdg-open.
bool openDocument(String path, String? searchPath) {
  final opener = whichIn('xdg-open', searchPath);
  return opener != null && _detached([opener, path], p.dirname(path));
}

/// A web page (an https link already checked) in the default browser.
bool openWebPage(String url, String? searchPath, String home) {
  final opener = whichIn('xdg-open', searchPath);
  return opener != null && _detached([opener, url], home);
}

/// desktop_generic.TERMINALS: a terminal and what comes before the command.
const terminals = [
  ('xdg-terminal-exec', <String>[]),
  ('kgx', ['--']),
  ('ptyxis', ['--']),
  ('gnome-terminal', ['--']),
  ('konsole', ['-e']),
  ('cosmic-term', ['--']),
  ('xfce4-terminal', ['-x']),
  ('foot', <String>[]),
  ('alacritty', ['-e']),
  ('kitty', <String>[]),
  ('wezterm', ['start', '--']),
  ('xterm', ['-e']),
];

/// desktop.other_session: XDG_CURRENT_DESKTOP names a desktop and none of
/// its names is Hyprland (a COSMIC or Plasma session on a PC that also has
/// Omarchy); unset says nothing (a user service may not see the variable).
bool otherSession(Map<String, String> env) {
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '')
      .toUpperCase()
      .split(':')
      .where((n) => n.isNotEmpty)
      .toList();
  return names.isNotEmpty && !names.contains('HYPRLAND');
}

Desktop detectDesktop(AppIdentity identity, Posix posix) {
  final env = identity.environment;
  final wanted = env['MAPRISMA_DESKTOP'];
  final omarchy =
      wanted == 'omarchy' ||
      wanted != 'generic' &&
          !otherSession(env) &&
          Directory(
            env['OMARCHY_PATH']?.isNotEmpty == true
                ? env['OMARCHY_PATH']!
                : '/usr/share/omarchy',
          ).existsSync();
  return omarchy
      ? OmarchyDesktop(identity, posix)
      : GenericDesktop(identity.environment);
}

final class GenericDesktop implements Desktop {
  GenericDesktop([this.environment = const {}]);
  final Map<String, String> environment;
  @override
  String get name => 'generic';

  /// desktop_generic.terminal: $TERMINAL when it is a plain program name,
  /// else the first known one installed.
  List<String>? terminal() {
    final own = environment['TERMINAL'] ?? '';
    final path = environment['PATH'];
    if (own.isNotEmpty && RegExp(r'^[A-Za-z0-9._+-]{1,64}$').hasMatch(own)) {
      final found = whichIn(own, path);
      if (found != null) {
        final known = terminals.where((t) => t.$1 == own).firstOrNull;
        return [
          found,
          ...known?.$2 ?? ['-e'],
        ];
      }
    }
    for (final (program, follow) in terminals) {
      final found = whichIn(program, path);
      // It exits with an error when it finds no terminal entry, and a
      // detached start would hide that: then the next one on the list.
      if (found != null &&
          program == 'xdg-terminal-exec' &&
          !_resolves(found)) {
        continue;
      }
      if (found != null) return [found, ...follow];
    }
    return null;
  }

  bool _resolves(String launcher) {
    try {
      return Process.runSync(launcher, [
            '--print-id',
          ], environment: environment).exitCode ==
          0;
    } on ProcessException {
      return false;
    }
  }

  @override
  bool runStepsInTerminal(List<List<String>> steps, String prompt) {
    final real = steps.where((s) => s.isNotEmpty).toList();
    if (real.isEmpty) return false;
    final script =
        '${real.map(shellJoin).join(' && ')}; echo; read -r -p ${shellQuote(prompt)} _';
    return openTerminal(['bash', '-c', script], environment['HOME'] ?? '/');
  }

  @override
  bool openTerminal(List<String> argv, String cwd) {
    final launcher = terminal();
    return launcher != null && _detached([...launcher, ...argv], cwd);
  }

  @override
  String? get themeDir => null;
  // The desktop's palette where Maprisma's sister apps read it (COSMIC's
  // theme, kdeglobals, Maprisma Shell's scheme on Hyprland); empty elsewhere:
  // Flutter follows platform brightness there, no GTK import or gsettings call.
  @override
  Map<String, String> themeColors() => desktopPalette(environment);
  late final _gtkFonts = GtkFonts(environment);
  @override
  Map<String, String> fonts() => desktopFonts(environment, gtk: _gtkFonts.read);
}

final class OmarchyDesktop implements Desktop {
  OmarchyDesktop(this.identity, this.posix);
  final AppIdentity identity;
  final Posix posix;
  @override
  String get name => 'omarchy';

  /// desktop_omarchy.run_steps_in_terminal: Omarchy's floating terminal (one
  /// line through bash), else xdg-terminal-exec.
  @override
  bool runStepsInTerminal(List<List<String>> steps, String prompt) {
    final real = steps.where((s) => s.isNotEmpty).toList();
    if (real.isEmpty) return false;
    final line = real.map(shellJoin).join(' && ');
    final path = identity.environment['PATH'];
    final floating = whichIn(
      'omarchy-launch-floating-terminal-with-presentation',
      path,
    );
    if (floating != null) return _detached([floating, line], identity.home);
    final launcher = whichIn('xdg-terminal-exec', path);
    return launcher != null &&
        _detached([launcher, 'bash', '-c', line], identity.home);
  }

  /// desktop_omarchy.open_terminal: xdg-terminal-exec, a new window.
  @override
  bool openTerminal(List<String> argv, String cwd) {
    final launcher = whichIn('xdg-terminal-exec', identity.environment['PATH']);
    return launcher != null && _detached([launcher, ...argv], cwd);
  }

  late final _gtkFonts = GtkFonts(identity.environment);
  @override
  Map<String, String> fonts() =>
      desktopFonts(identity.environment, gtk: _gtkFonts.read);

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
