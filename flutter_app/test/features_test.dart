import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/features.dart';

void main() {
  NativeFeatureContribution contribution(FeatureDescriptor descriptor) =>
      NativeFeatureContribution(descriptor: descriptor, onOpen: () {});

  test(
    'feature contributions retain ordering and separate navigation slots',
    () {
      var opened = 0;
      final registry = FeatureRegistry([
        contribution(MaprismaFeatures.reports),
        NativeFeatureContribution(
          descriptor: MaprismaFeatures.askAi,
          onOpen: () => opened++,
        ),
        contribution(MaprismaFeatures.projectCenter),
      ]);

      expect(registry.forSlot(FeatureSlot.page).map((f) => f.descriptor.id), [
        'reports',
        'ai-project-center',
      ]);
      expect(registry.forSlot(FeatureSlot.assistant), hasLength(1));
      registry['ask-ai']!.onOpen();
      expect(opened, 1);
      expect(registry['unavailable'], isNull);
      expect(() => registry.contributions.clear(), throwsUnsupportedError);
    },
  );

  test('registry refuses conflicting and incompatible contributions', () {
    expect(
      () => FeatureRegistry([
        contribution(MaprismaFeatures.reports),
        contribution(MaprismaFeatures.reports),
      ]),
      throwsArgumentError,
    );
    expect(
      () => FeatureRegistry([
        contribution(
          const FeatureDescriptor(
            id: 'future',
            title: 'Future feature',
            icon: Icons.extension,
            selectedIcon: Icons.extension,
            slot: FeatureSlot.page,
            uiApiVersion: featureUiApiVersion + 1,
          ),
        ),
      ]),
      throwsArgumentError,
    );
  });
}
