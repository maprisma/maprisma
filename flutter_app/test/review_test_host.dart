import 'package:flutter/material.dart';
import 'package:asterism/task_card.dart';
import 'package:asterism/addon_details.dart';
import 'package:asterism/connections_view.dart';
import 'package:asterism/agent_action_dialog.dart';
import 'package:asterism/model_removal_dialog.dart';

Future<bool> _present(
  BuildContext context,
  String Function(String) tr,
  Widget Function(VoidCallback, VoidCallback) review,
) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: TaskHost(
            spec: TaskCardSpec(
              title: 'Review',
              child: review(
                () => Navigator.pop(context, true),
                () => Navigator.pop(context, false),
              ),
            ),
            graph: const {'nodes': [], 'edges': []},
            tr: tr,
            onClose: () => Navigator.pop(context, false),
          ),
        ),
      ),
    ) ??
    false;

Future<bool> confirmAddonInstall(
  BuildContext c,
  Map<String, dynamic> p,
  String Function(String) tr,
) => _present(
  c,
  tr,
  (yes, no) =>
      AddonInstallReview(item: p, tr: tr, onConfirm: yes, onCancel: no),
);
Future<bool> confirmAddonRemoval(
  BuildContext c,
  Map<String, dynamic> p,
  String Function(String) tr,
) => _present(
  c,
  tr,
  (yes, no) =>
      AddonRemovalReview(plan: p, tr: tr, onConfirm: yes, onCancel: no),
);
Future<bool> confirmConnection(
  BuildContext c,
  Map<String, dynamic> p,
  String Function(String) tr,
) => _present(
  c,
  tr,
  (yes, no) => ConnectionReview(plan: p, tr: tr, onConfirm: yes, onCancel: no),
);
Future<bool> confirmAgentAction(
  BuildContext c,
  Map<String, dynamic> p,
  String Function(String) tr,
) => _present(
  c,
  tr,
  (yes, no) => AgentActionReview(plan: p, tr: tr, onConfirm: yes, onCancel: no),
);
Future<bool> confirmModelRemoval(
  BuildContext c,
  Map<String, dynamic> p,
  String Function(String) tr,
) => _present(
  c,
  tr,
  (yes, no) =>
      ModelRemovalReview(preview: p, tr: tr, onConfirm: yes, onCancel: no),
);
