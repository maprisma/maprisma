import 'package:flutter/material.dart';
import 'system_map_view.dart' show separateMountHint, simplifyHint;

class MapWelcome extends StatelessWidget {
  const MapWelcome({
    super.key,
    required this.tr,
    required this.busy,
    required this.skipSearch,
    required this.searched,
    required this.onLook,
    required this.onSkip,
    required this.onSystem,
    required this.onAgents,
  });
  final String Function(String) tr;
  final bool busy, skipSearch, searched;
  final VoidCallback onLook, onSkip, onSystem, onAgents;
  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(
      '${tr('Welcome to {0}').replaceAll('{0}', 'Maprisma')}\n${tr(separateMountHint)}\n${tr(simplifyHint)}\n${tr('Only this PC is inspected. Nothing is sent and no detected program is run. You can skip the disk search.')}',
    ),
    actions: [
      if (!skipSearch && !searched) ...[
        TextButton(
          onPressed: busy ? null : onLook,
          child: Text(tr('Look at this PC')),
        ),
        TextButton(onPressed: busy ? null : onSkip, child: Text(tr('Skip'))),
      ],
      TextButton(
        onPressed: busy ? null : onSystem,
        child: Text(tr('System Map')),
      ),
      TextButton(onPressed: busy ? null : onAgents, child: Text(tr('Agents'))),
    ],
  );
}
