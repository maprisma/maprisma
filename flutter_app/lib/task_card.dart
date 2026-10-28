import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agent_map.dart';
import 'task_focus.dart';

enum TaskCardWidth { half, full }

class TaskCardSpec {
  const TaskCardSpec({
    required this.title,
    required this.child,
    this.width = TaskCardWidth.half,
    this.focus = const {},
    this.closable = true,
  });
  final String title;
  final Widget child;
  final TaskCardWidth width;
  final Set<String> focus;
  final bool closable;
}

class TaskHost extends StatelessWidget {
  const TaskHost({
    super.key,
    required this.spec,
    required this.graph,
    required this.tr,
    required this.onClose,
  });
  final TaskCardSpec spec;
  final Map<String, dynamic> graph;
  final String Function(String) tr;
  final VoidCallback onClose;

  static bool usesHalfCard(
    TaskCardWidth width,
    double availableWidth,
    bool hasFocusNodes,
  ) => width == TaskCardWidth.half && availableWidth >= 900 && hasFocusNodes;

  @override
  Widget build(BuildContext context) {
    final focused = focusGraph(graph, spec.focus, const [
      'MCP servers and skills',
      'Agents',
      'Providers',
      'Models',
    ]);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (spec.closable) onClose();
        },
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final half = usesHalfCard(
              spec.width,
              constraints.maxWidth,
              (focused.graph['nodes'] as List).isNotEmpty,
            );
            final colors = Theme.of(context).colorScheme;
            final card = Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: Material(
                    key: const ValueKey('task-card'),
                    color: colors.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  spec.title,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: spec.closable ? onClose : null,
                                icon: const Icon(Icons.arrow_back),
                                label: Text(tr('Back')),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(child: spec.child),
                      ],
                    ),
                  ),
                ),
                if (half)
                  Positioned(
                    left: -4,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            );
            return Padding(
              padding: const EdgeInsets.all(12),
              child: half
                  ? Row(
                      key: const ValueKey('half-task'),
                      children: [
                        Expanded(
                          child: AgentMap(
                            graph: focused.graph,
                            columns: focused.columns,
                            tr: tr,
                            onAgent: (_) {},
                            readOnly: true,
                            anchors: spec.focus,
                          ),
                        ),
                        SizedBox(
                          width: math.max(460, (constraints.maxWidth - 24) / 2),
                          child: card,
                        ),
                      ],
                    )
                  : SizedBox.expand(
                      key: const ValueKey('full-task'),
                      child: card,
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// Reuses existing review contents while keeping actions inside the task card.
class TaskReview extends StatelessWidget {
  const TaskReview({
    super.key,
    this.title,
    required this.content,
    required this.actions,
  });
  final Widget? title;
  final Widget content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [?title, const SizedBox(height: 16), content],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 8, runSpacing: 8, children: actions),
      ),
    ],
  );
}

/// Preserve task-view state under a review without keeping a main map alive.
class RetainedTaskView extends StatelessWidget {
  const RetainedTaskView({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;
  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !visible,
    child: ExcludeFocus(
      excluding: !visible,
      child: TickerMode(enabled: visible, child: child),
    ),
  );
}
