import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'desktop.dart';
import 'scan_files.dart';

final class AgentRecord {
  AgentRecord(
    this.adapter, {
    required this.name,
    required this.icon,
    this.iconFont = '',
    required this.installed,
    this.version = '',
    this.source = '',
    this.isDefault = false,
  });
  final Adapter adapter;
  final String name, icon, iconFont;
  final bool installed, isDefault;
  final String version, source;
  String get command => adapter.command;
  Map<String, dynamic> toJson() => {
    'command': command,
    'name': name,
    'icon': icon,
    'icon_font': iconFont,
    'installed': installed,
    'version': version,
    'source': source,
    'default': isDefault,
  };
}

const robotIcon = '\u{f06a9}';
const agentMenu = '/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc';
final _menuEntry = RegExp(
  r'^\s*"setup\.default\.agent\.([a-z0-9-]{1,64})"\s*:\s*(\{.*\})\s*,?\s*$',
  multiLine: true,
);
final _agentName = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');

/// Python's str[:n]: code points, not UTF-16 units.
String _points(String text, int n) => String.fromCharCodes(text.runes.take(n));

final class AgentCatalog {
  AgentCatalog(this.files, this.desktop, {List<Adapter>? adapters})
    : adapters = adapters ?? builtinAdapters();
  final ScanFiles files;
  final Desktop desktop;
  List<Adapter> adapters;
  Adapter? adapter(String command) {
    for (final a in [
      ...adapters.where((a) => (a.facts['offered'] ?? true) == true),
      ...adapters.where((a) => a.facts['offered'] == false),
    ]) {
      if (a.command == command) return a;
    }
    return null;
  }

  List<String> installCandidates(String spec) {
    final base = spec.split('[').first;
    return {
          base
              .replaceAll(RegExp(r'[:/@]+'), '-')
              .replaceAll(RegExp(r'^-+|-+$'), ''),
          base.split('/').last.split(':').last.replaceFirst(RegExp(r'^@+'), ''),
        }
        .where(
          (s) =>
              RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$').hasMatch(s) &&
              !s.contains('..'),
        )
        .toList();
  }

  String? wrapperSpec(String command) {
    final text = files.text('~/.local/bin/$command', limit: 4096);
    final found = RegExp(
      r'^exec mise x "([^"\n]{1,512})" -- "([A-Za-z0-9._-]{1,64})" "\$@"$',
      multiLine: true,
    ).firstMatch(text ?? '');
    return found != null && found[2] == command ? found[1] : null;
  }

  bool ownInstall(String command) {
    final path = files.expand('~/.local/bin/$command');
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      try {
        final target = File(path).resolveSymbolicLinksSync();
        return FileSystemEntity.typeSync(target) == FileSystemEntityType.file;
      } on FileSystemException {
        return false;
      }
    }
    final fdPath = FileSystemEntity.typeSync(path, followLinks: false);
    if (fdPath != FileSystemEntityType.file) return false;
    final text = files.text(path, limit: 4096);
    return text == null ||
        !RegExp(r'^mise use -g', multiLine: true).hasMatch(text) &&
            wrapperSpec(command) == null;
  }

  String? miseInstall(String spec) {
    for (final name in installCandidates(spec)) {
      final path = files.expand('~/.local/share/mise/installs/$name');
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      if (files
          .list(path)
          .any(
            (p) =>
                FileSystemEntity.typeSync(p, followLinks: false) ==
                FileSystemEntityType.directory,
          )) {
        return path;
      }
    }
    return null;
  }

  String miseVersion(String folder) {
    final version = RegExp(r'^[0-9][0-9A-Za-z.+_\-]{0,63}$');
    for (final name in ['global', 'latest']) {
      try {
        final target = p.basename(Link(p.join(folder, name)).targetSync());
        if (version.hasMatch(target)) return target;
      } on FileSystemException {
        /* ordinary version folders below */
      }
    }
    final candidates = files
        .list(folder)
        .where(
          (path) =>
              FileSystemEntity.typeSync(path, followLinks: false) ==
                  FileSystemEntityType.directory &&
              version.hasMatch(p.basename(path)),
        )
        .toList();
    candidates.sort(
      (a, b) =>
          File(b).statSync().modified.compareTo(File(a).statSync().modified),
    );
    return candidates.isEmpty ? '' : p.basename(candidates.first);
  }

  String? packageVersion(String name) {
    final root = files.identity.environment['MAPRISMA_SCAN_SYSTEM_ROOT'] ?? '';
    for (final path in files.list(
      '$root/var/lib/pacman/local',
      limit: 40000,
      allowRootOwned: true,
    )) {
      final entry = p.basename(path);
      if (!entry.startsWith('$name-')) continue;
      final parts = entry.substring(name.length + 1).split('-');
      if (parts.length == 2 &&
          parts[0].isNotEmpty &&
          parts[1].replaceAll('.', '').isNotEmpty &&
          RegExp(r'^[0-9.]+$').hasMatch(parts[1])) {
        return parts[0].split(':').last;
      }
    }
    return null;
  }

  bool _offered(Adapter a) => (a.facts['offered'] ?? true) == true;

  String _iconFont(Adapter a) =>
      a.facts['icon_font'] == 'omarchy' ? 'omarchy' : '';

  /// Python agents.FALLBACK: the offered adapters in their built-in order.
  List<(String, String, String, String)> get fallback => [
    for (final a in adapters.where(_offered))
      (a.command, a.label, a.icon, _iconFont(a)),
  ];

  /// Python desktop_*.agent_catalog(): Omarchy's agent menu, in its order (null:
  /// unreadable or the built-in list); generic desktops turn Omarchy glyphs into the robot.
  List<(String, String, String, String)>? desktopCatalog() {
    if (desktop.name != 'omarchy') {
      return [
        for (final (command, label, icon, font) in fallback)
          (
            command,
            label,
            font == 'omarchy' ? robotIcon : icon,
            font == 'omarchy' ? '' : font,
          ),
      ];
    }
    final found = <(String, String, String, String)>[];
    final text =
        files.text(agentMenu, limit: 1024 * 1024, allowRootOwned: true) ?? '';
    for (final match in _menuEntry.allMatches(text)) {
      Object? entry;
      try {
        entry = jsonDecode(match[2]!);
      } on FormatException {
        continue;
      }
      final command = match[1]!;
      if (entry is! Map || !_agentName.hasMatch(command)) continue;
      final label = entry['label'], icon = entry['icon'];
      if (label is! String || icon is! String) continue;
      found.add((
        command,
        _points(label, 40),
        _points(icon, 2),
        entry['iconFont'] == 'omarchy' ? 'omarchy' : '',
      ));
    }
    final list = found.isEmpty ? fallback : found;
    bool same(List a, List b) =>
        a.length == b.length &&
        [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
    return same(list, fallback) ? null : list;
  }

  /// A program of a distribution package or another installer: on PATH, but
  /// not mise's shims and wrappers or ~/.local/bin, which can be stubs that
  /// install the agent at its first start (the checks above read those).
  bool onSystemPath(String command) {
    final env = files.identity.environment;
    final data = env['MISE_DATA_DIR'] ?? '';
    final mise = data.startsWith('/')
        ? data
        : files.expand('~/.local/share/mise');
    final own = files.expand('~/.local/bin');
    final folders = (env['PATH'] ?? '')
        .split(':')
        .where(
          (f) =>
              !p.equals(f, own) && !p.equals(f, mise) && !p.isWithin(mise, f),
        )
        .join(':');
    return whichIn(command, folders) != null;
  }

  /// Python agents.detect(): (installed, version, source) for one agent.
  (bool, String, String) detect(String command, Adapter? a) {
    if (a != null &&
        (a.facts.containsKey('installer') || a.facts.containsKey('download'))) {
      final version = installedVersion(command);
      if (version != null) {
        return (
          true,
          a.facts['short_version'] == true ? version.split('-').first : version,
          'own',
        );
      }
      if (ownInstall(command)) return (true, '', 'own');
      // Its recipe may install through mise first (Antigravity CLI).
      final folder = miseInstall(a.facts['spec'] as String? ?? command);
      if (folder != null) return (true, miseVersion(folder), 'mise');
      return onSystemPath(command) ? (true, '', 'system') : (false, '', '');
    }
    final package = a?.facts['package'] as String?;
    if (package != null) {
      final found = packageVersion(package);
      if (found != null) return (true, found, 'package');
      if (a!.facts['package_only'] == true) return (false, '', '');
    }
    final spec = wrapperSpec(command) ?? a?.facts['spec'] as String? ?? command;
    final folder = miseInstall(spec);
    if ((a == null || (a.facts['own_install_counts'] ?? true) == true) &&
        ownInstall(command)) {
      return (true, folder == null ? '' : miseVersion(folder), 'own');
    }
    if (folder != null) return (true, miseVersion(folder), 'mise');
    final counts = a == null || (a.facts['own_install_counts'] ?? true) == true;
    return counts && onSystemPath(command)
        ? (true, '', 'system')
        : (false, '', '');
  }

  /// The app's own version-folder install (install_ctl): `current` of
  /// `~/.local/bin/<command>`'s folder chain, marked `.maprisma`.
  String? installedVersion(String command) {
    final String target;
    try {
      target = Link(files.expand('~/.local/bin/$command')).targetSync();
    } on FileSystemException {
      return null;
    }
    var parent = p.dirname(target);
    while (parent != p.dirname(parent) && parent != '.') {
      if (p.basename(parent) == 'current') {
        final root = p.dirname(parent);
        if (!files.exists('$root/.maprisma') &&
            !files.exists('$root/.ai-agents-map')) {
          return null;
        }
        try {
          return Link(
            '$root/current',
          ).targetSync().replaceFirst(RegExp(r'^v+'), '');
        } on FileSystemException {
          return '';
        }
      }
      parent = p.dirname(parent);
    }
    return null;
  }

  /// Python agents.list_agents(): the desktop's offer plus the app's own
  /// agents, installed ones first (the default leading), each in offer order.
  List<AgentRecord> scan() {
    final chosen = desktop.name == 'omarchy'
        ? (files.text('~/.config/omarchy/defaults/agent', limit: 256) ?? '')
              .trim()
              .split('\n')
              .first
        : '';
    final isDefault = _agentName.hasMatch(chosen) ? chosen : '';
    final known = [...(desktopCatalog() ?? fallback)];
    final listed = {for (final k in known) k.$1};
    known.addAll([
      for (final a in adapters.where((a) => !_offered(a)))
        if (!listed.contains(a.command))
          (a.command, a.label, a.icon, _iconFont(a)),
    ]);
    final result = <AgentRecord>[];
    for (final (command, label, icon, font) in known) {
      final a = adapter(command);
      final (installed, version, source) = detect(command, a);
      result.add(
        AgentRecord(
          a ?? Adapter.unknown(command, label),
          name: a != null && a.fullName.isNotEmpty ? a.fullName : label,
          icon: icon.isEmpty ? robotIcon : icon,
          iconFont: font,
          installed: installed,
          version: version,
          source: source,
          isDefault: command == isDefault,
        ),
      );
    }
    final order = {
      for (var i = 0; i < result.length; i++) result[i].command: i,
    };
    result.sort((a, b) {
      if (a.installed != b.installed) return a.installed ? -1 : 1;
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return order[a.command]!.compareTo(order[b.command]!);
    });
    return result;
  }
}
