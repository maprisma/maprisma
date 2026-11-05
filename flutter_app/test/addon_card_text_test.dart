// An add-on card says why it is not used: made for Asterism (remove it),
// not verified, or not available in this version.
import 'package:maprisma/map_addons_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a refused card names Asterism leftovers before anything else', (
    tester,
  ) async {
    Map<String, dynamic> item(String id, Map<String, dynamic> extra) => {
      'id': id,
      'name': id,
      'version': '',
      'kind': 'feature',
      'state': 'refused',
      'supported': false,
      'verified': false,
      'legacy': false,
      'enabled': false,
      'removable': true,
      'provides': const [],
      ...extra,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapAddonsFocus(
            category: 2,
            items: [
              item('agent-goose', {'legacy': true}),
              item('broken', {}),
              item('ui-feature', {'state': 'verified', 'verified': true}),
            ],
            nodes: const [],
            entries: const [],
            detected: const {},
            busy: false,
            online: true,
            tr: (s) => s,
            onBack: () {},
            onToggle: (_, _) async {},
            onCatalog: () {},
            onOnline: (_) {},
            onInstall: (_) {},
            onMenu: (_, _) {},
            onNode: (_) {},
            onModels: () {},
            onConnections: () {},
            onFolders: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Made for Asterism, this app's old name, and never loaded. Remove it: Maprisma brings its own copy.",
      ),
      findsOneWidget,
    );
    expect(
      find.text('This add-on could not be verified or loaded.'),
      findsOneWidget,
    );
    expect(find.text('Not available in this version'), findsOneWidget);
  });
}
