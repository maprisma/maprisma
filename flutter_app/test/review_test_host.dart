import 'package:flutter/material.dart';
import 'package:maprisma/task_card.dart';
import 'package:maprisma/addon_details.dart';
import 'package:maprisma/connections_view.dart';
import 'package:maprisma/agent_action_dialog.dart';
import 'package:maprisma/model_removal_dialog.dart';

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
