import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class ProjectStartMenuController extends ChangeNotifier {
  final menu = MenuController();
  String? command;
  String? path;

  void openFor(String agent, String folder) {
    command = agent;
    path = folder;
    notifyListeners();
  }
}

class ProjectStartMenu extends StatefulWidget {
  const ProjectStartMenu({
    super.key,
    required this.command,
    required this.projects,
    required this.controller,
    required this.enabled,
    required this.tr,
    required this.onStart,
  });
  final String command;
  final Map projects;
  final ProjectStartMenuController controller;
  final bool enabled;
  final String Function(String) tr;
  final Future<void> Function(Map<String, dynamic>) onStart;

  @override
  State<ProjectStartMenu> createState() => _ProjectStartMenuState();
}

class _ProjectStartMenuState extends State<ProjectStartMenu> {
  late String _path;
  bool _custom = false;

  @override
  void initState() {
    super.initState();
    _path = widget.projects['default'] as String;
    widget.controller.addListener(_requested);
  }

  @override
  void didUpdateWidget(covariant ProjectStartMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_custom) _path = widget.projects['default'] as String;
  }

  Future<void> _requested() async {
    if (!widget.enabled || widget.controller.command != widget.command) return;
    setState(() {
      _path = widget.controller.path!;
      _custom = true;
    });
    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 150),
    );
    if (mounted) widget.controller.menu.open();
  }

  void _start(bool outside) {
    widget.controller.menu.close();
    widget.onStart({
      'command': widget.command,
      'path': _path,
      'outside': outside,
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_requested);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.projects['history'] as List;
    final description = widget.tr(
      widget.projects['pinned'] == _path
          ? 'Pinned default'
          : (_path == widget.projects['default']
                ? 'Default folder'
                : 'Selected project'),
    );
    return MenuAnchor(
      controller: widget.controller.menu,
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.play_arrow),
          onPressed: widget.enabled ? () => _start(false) : null,
          child: Text('${widget.tr('Start')} · $description'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.open_in_new),
          onPressed: widget.enabled ? () => _start(true) : null,
          child: Text(widget.tr('Start in terminal')),
        ),
        SizedBox(
          width: 360,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Tooltip(
              message: _path,
              child: Text(_path, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open),
          closeOnActivate: false,
          onPressed: widget.enabled
              ? () async {
                  final chosen = await getDirectoryPath();
                  if (chosen != null && mounted) {
                    setState(() {
                      _path = chosen;
                      _custom = true;
                    });
                  }
                }
              : null,
          child: Text(widget.tr('Choose folder…')),
        ),
        MenuItemButton(
          closeOnActivate: false,
          onPressed: widget.enabled
              ? () => setState(() {
                  _path = widget.projects['default'] as String;
                  _custom = false;
                })
              : null,
          child: Text(widget.tr('Use default folder')),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownMenu<String>(
            key: ValueKey(_path),
            width: 336,
            menuHeight: 240,
            enabled: widget.enabled && history.isNotEmpty,
            enableFilter: true,
            enableSearch: true,
            requestFocusOnTap: true,
            hintText: widget.tr('Select a recent project…'),
            dropdownMenuEntries: [
              for (final entry in history)
                DropdownMenuEntry(
                  value: entry['path'] as String,
                  label: entry['path'] as String,
                  enabled: entry['available'] == true,
                ),
            ],
            onSelected: (value) {
              if (value != null) {
                setState(() {
                  _path = value;
                  _custom = true;
                });
              }
            },
          ),
        ),
      ],
      builder: (context, menu, _) => FilledButton.icon(
        onPressed: widget.enabled
            ? () => menu.isOpen ? menu.close() : menu.open()
            : null,
        icon: const Icon(Icons.play_arrow),
        label: Text(widget.tr('Start')),
      ),
    );
  }
}
