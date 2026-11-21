import 'package:flutter/material.dart';

/// Version of the shell's native feature contribution API. Backend plugins
/// negotiate their process protocol separately; native widget code is compiled
/// with the shell and needs an app build when new widget behavior is introduced.
const featureUiApiVersion = 1;

enum FeatureSlot { page, assistant }

/// A feature's contribution to navigation. The shell owns placement, themes and
/// keyboard behavior; feature modules own their pages and actions.
@immutable
class FeatureDescriptor {
  const FeatureDescriptor({
    required this.id,
    required this.title,
    required this.icon,
    required this.selectedIcon,
    required this.slot,
    this.uiApiVersion = featureUiApiVersion,
  });

  final String id;
  final String title;
  final IconData icon;
  final IconData selectedIcon;
  final FeatureSlot slot;
  final int uiApiVersion;
}

typedef FeaturePageBuilder = Widget Function(BuildContext context);

/// Page builders and invocation callbacks are supplied by the feature, allowing
/// the shell to list and open contributions without a feature-name switch.
class NativeFeatureContribution {
  const NativeFeatureContribution({
    required this.descriptor,
    required this.onOpen,
    this.buildPage,
  });

  final FeatureDescriptor descriptor;
  final VoidCallback onOpen;
  final FeaturePageBuilder? buildPage;
}

class FeatureRegistry {
  FeatureRegistry(Iterable<NativeFeatureContribution> contributions) {
    for (final contribution in contributions) {
      final descriptor = contribution.descriptor;
      if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(descriptor.id) ||
          descriptor.title.trim().isEmpty) {
        throw ArgumentError('Invalid feature descriptor');
      }
      if (descriptor.uiApiVersion != featureUiApiVersion) {
        throw ArgumentError('Unsupported feature UI API');
      }
      if (_features.containsKey(descriptor.id)) {
        throw ArgumentError('Duplicate feature identifier');
      }
      _features[descriptor.id] = contribution;
    }
  }

  final _features = <String, NativeFeatureContribution>{};

  List<NativeFeatureContribution> get contributions =>
      List.unmodifiable(_features.values);

  List<NativeFeatureContribution> forSlot(FeatureSlot slot) =>
      List.unmodifiable(
        _features.values.where((feature) => feature.descriptor.slot == slot),
      );

  NativeFeatureContribution? operator [](String id) => _features[id];
}

/// First-party native presentations. Backend identities are stable across
/// independent plugin versions and are also used by the process plugin API.
abstract final class MaprismaFeatures {
  static const reports = FeatureDescriptor(
    id: 'reports',
    title: 'Reports',
    icon: Icons.assessment_outlined,
    selectedIcon: Icons.assessment,
    slot: FeatureSlot.page,
  );

  static const askAi = FeatureDescriptor(
    id: 'ask-ai',
    title: 'Ask AI',
    icon: Icons.auto_awesome_outlined,
    selectedIcon: Icons.auto_awesome,
    slot: FeatureSlot.assistant,
  );

  static const projectCenter = FeatureDescriptor(
    id: 'ai-project-center',
    title: 'AI Project Center',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree,
    slot: FeatureSlot.page,
  );
}
