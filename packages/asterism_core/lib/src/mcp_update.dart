import 'dart:io';
import 'package:path/path.dart' as p;
import 'connect_apply.dart';
import 'desktop.dart' show whichIn;
import 'found_scan.dart' show FoundScan;
import 'map_edits.dart' show chainPlans, mergePlans;
import 'mcp_plans.dart';
import 'py_values.dart';

/// mcp_update: every user of an app's older version moved to its newer one
/// (a found program with update_from), as one plan with a preview, a backup
/// and Undo: the agents' entries and the list's entries that start an older
/// program get the new one (args into the old folder move along), the
/// user's links into the old folder point into the new one, and the old
/// folders go into the backup (deleted after [retiredDays]). A newer
/// AppImage is unpacked (found.unpack) before.

final _serverName = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

final class McpUpdate {
  McpUpdate(this.home, this.mcp, this.config, {this.searchPath});
  final String home;
  final McpPlans mcp;
  final ConfigFiles config;
  final String? searchPath;

  List<String> get linkDirs => [
    p.join(home, '.local/bin'),
    p.join(home, 'bin'),
  ];

  static String _real(String path) => FoundScan.resolve(path);

  static bool _inside(String path, String folder) {
    final f = folder.endsWith('/')
        ? folder.substring(0, folder.length - 1)
        : folder;
    return path == folder || path.startsWith('$f/');
  }

  /// new_folder: where the newer version lives (or will, once unpacked).
  String newFolder(Map c) {
    if ('${c['appimage']}'.isNotEmpty) {
      return p.join(
        home,
        'Applications',
        FoundScan.appimageStem('${c['appimage']}'),
      );
    }
    final real = _real('${c['program']}');
    final apps = p.join(_real(home), 'Applications');
    if (!p.isWithin(apps, real)) {
      throw FormatException('${c['program']} is not in ~/Applications');
    }
    return p.join(
      home,
      'Applications',
      p.split(p.relative(real, from: apps)).first,
    );
  }

  /// _moved: a path inside an old folder, at the same place in the new one.
  static String moved(String path, List<String> oldFolders, String folder) {
    final real = _real(path);
    for (final old in oldFolders) {
      for (final form in [old, _real(old)]) {
        if (_inside(real, form)) {
          final cut = form.endsWith('/')
              ? form.substring(0, form.length - 1)
              : form;
          return folder + real.substring(cut.length);
        }
      }
    }
    return path;
  }

  List<String> _old(Map c) => [
    for (final x in c['old_folders'] as List? ?? const []) '$x',
  ];

  /// links: (link, its target now, new target) for the user's links into
  /// the old folders.
  List<(String, String, String)> links(Map c) {
    final folder = newFolder(c);
    final found = <(String, String, String)>[];
    for (final place in linkDirs) {
      List<String> entries;
      try {
        entries = [
          for (final e in Directory(place).listSync(followLinks: false)) e.path,
        ]..sort();
      } on FileSystemException {
        continue;
      }
      for (final link in entries.take(500)) {
        if (!FileSystemEntity.isLinkSync(link)) continue;
        final target = Link(link).targetSync();
        final absolute = p.isAbsolute(target)
            ? target
            : '${p.dirname(link)}/$target';
        final next = moved(absolute, _old(c), folder);
        if (next != absolute) found.add((link, target, next));
      }
    }
    return found;
  }

  static String _abspath(String path) => p.normalize(p.absolute(path));

  /// _new_entry: the entry starting the new version, null when it does not
  /// start an old one.
  Map<String, dynamic>? newEntry(Map? entry, Map c, Set<String> linked) {
    if (entry == null || entry['transport'] != 'stdio') return null;
    var command = '${entry['command']}';
    if (command == '~' || command.startsWith('~/')) {
      command = home + command.substring(1);
    }
    final program = whichIn(command, searchPath) ?? command;
    if (linked.contains(_abspath(program))) {
      return null; // starts a link that is moved to the new version
    }
    final replaces = [for (final x in c['replaces'] as List? ?? const []) '$x'];
    final old = {...replaces.map(_real), ...replaces};
    if (!old.contains(program) && !old.contains(_real(program))) return null;
    final folder = newFolder(c);
    var newProgram = moved(program, _old(c), folder);
    if (newProgram == program) {
      newProgram = '${c['program']}'; // the old program outside its folder
    }
    return {
      ...Map<String, dynamic>.from(entry),
      'command': newProgram,
      'args': [
        for (final a in entry['args'] as List? ?? const [])
          '$a'.startsWith('/') ? moved('$a', _old(c), folder) : '$a',
      ],
    };
  }

  /// mcp_library.text_with.
  static String libraryText(Map<String, dynamic> servers) {
    final keys = servers.keys.toList()..sort(pyCompare);
    return '${pyJsonDumps({
      'servers': {for (final k in keys) k: servers[k]},
    }, indent: 2, ensureAscii: false)}\n';
  }

  /// plan: the whole update of one app. agents: the installed agents.
  Plan plan(Map c, List<String> agents) {
    final folder = newFolder(c);
    final movedLinks = links(c);
    final linked = {for (final (link, _, _) in movedLinks) _abspath(link)};
    final plans = <Plan>[];
    for (final agent in agents) {
      if (!mcp.supported(agent)) continue;
      for (final e in mcp.rawEntries(agent).entries) {
        if (!_serverName.hasMatch(e.key)) continue;
        final entry = newEntry(normalEntry(e.value), c, linked);
        if (entry != null) {
          plans.add(
            mcp.plan(agent, e.key, const [], remove: false, entry: entry),
          );
        }
      }
    }
    final listed = Plan('', '', '${c['name']}');
    final servers = mcp.library();
    final changed = <String, dynamic>{};
    for (final e in servers.entries) {
      final next = newEntry(e.value as Map?, c, linked);
      if (next != null) changed[e.key] = next;
    }
    if (changed.isNotEmpty) {
      final path = mcp.libraryFile;
      final old = config.read(path);
      final text = libraryText({...servers, ...changed});
      if (text != old) listed.changes.add(Change(path, old, text));
    }
    for (final (link, oldTarget, newTarget) in movedLinks) {
      listed.linksRemove.add((link, oldTarget));
      listed.linksAdd.add((link, newTarget));
    }
    listed.retire.addAll([
      for (final f in _old(c))
        if (FileSystemEntity.isDirectorySync(f) && f != folder) f,
    ]);
    return mergePlans([...plans, listed]);
  }

  /// plan_all: every app's update as one plan, each on top of the ones
  /// before (they edit the same settings files).
  Plan planAll(List<Map> candidates, List<String> agents) =>
      chainPlans(config, [for (final c in candidates) () => plan(c, agents)]);
}
