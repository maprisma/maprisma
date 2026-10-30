import 'dart:io';
import 'package:path/path.dart' as p;

/// agent_projects: project-folder choices for individual agents. Links are
/// resolved before launch: the agent's real working folder.
final class AgentProjects {
  AgentProjects(this.home);
  final String home;

  String _expand(String value) => value == '~'
      ? home
      : value.startsWith('~/')
      ? p.join(home, value.substring(2))
      : value;

  /// folder: an existing folder, links resolved; null otherwise.
  String? folder(dynamic value) {
    if (value is! String || value.isEmpty || value.contains('\x00')) {
      return null;
    }
    final path = _expand(value);
    if (!p.isAbsolute(path)) return null;
    try {
      final resolved = Directory(path).resolveSymbolicLinksSync();
      return FileSystemEntity.isDirectorySync(resolved) ? resolved : null;
    } on FileSystemException {
      return null;
    }
  }

  String selected(String command, dynamic saved, String fallback) {
    final value = saved is Map ? saved[command] : null;
    return folder(value) ?? folder(fallback) ?? home;
  }

  /// One optional pinned default per agent, independent of its history.
  Map<String, dynamic> pin(String command, String? chosen, dynamic saved) {
    final kept = saved is Map
        ? Map<String, dynamic>.from(saved)
        : <String, dynamic>{};
    if (chosen == null) {
      kept.remove(command);
    } else {
      final resolved = folder(chosen);
      if (resolved == null) {
        throw const FormatException('The project folder is unavailable');
      }
      kept[command] = resolved;
    }
    return kept;
  }

  /// All recorded folders, newest first; missing ones kept to be removed.
  List<String> history(String command, dynamic saved) {
    final values = saved is Map ? saved[command] ?? const [] : const [];
    if (values is! List) return [];
    final found = <String>[], seen = <String>{};
    for (final value in values) {
      if (value is String &&
          value.isNotEmpty &&
          !value.contains('\x00') &&
          p.isAbsolute(value) &&
          seen.add(value)) {
        found.add(value);
      }
    }
    return found;
  }

  Map<String, dynamic> used(String command, String chosen, dynamic saved) {
    final resolved = folder(chosen);
    if (resolved == null) {
      throw const FormatException('The project folder is unavailable');
    }
    final kept = saved is Map
        ? Map<String, dynamic>.from(saved)
        : <String, dynamic>{};
    kept[command] = [
      resolved,
      ...history(command, saved).where((x) => x != resolved),
    ].take(50).toList();
    return kept;
  }

  /// Only a history entry and its pin go; the file system is never touched.
  (Map<String, dynamic>, Map<String, dynamic>) forget(
    String command,
    String chosen,
    dynamic saved,
    dynamic pinned,
  ) {
    final kept = saved is Map
        ? Map<String, dynamic>.from(saved)
        : <String, dynamic>{};
    kept[command] = history(command, saved).where((x) => x != chosen).toList();
    final pins = pinned is Map
        ? Map<String, dynamic>.from(pinned)
        : <String, dynamic>{};
    if (pins[command] == chosen) pins.remove(command);
    return (kept, pins);
  }

  /// flutter_backend.projects: what the start dialog shows for one agent.
  Map<String, dynamic> projects(String command, Map saved) {
    final pinned = saved['agent_projects'];
    final pin = pinned is Map ? pinned[command] : null;
    return {
      'default': selected(command, pinned, '${saved['agent_folder'] ?? home}'),
      'pinned': pin is String ? pin : null,
      'history': [
        for (final path in history(
          command,
          saved['agent_project_history'] ?? {},
        ))
          {'path': path, 'available': folder(path) != null},
      ],
    };
  }
}
