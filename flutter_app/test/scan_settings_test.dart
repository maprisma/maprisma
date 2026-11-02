import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the border of the category cards: on, thickness, color', (
    tester,
  ) async {
    var layout = <String, dynamic>{};
    Widget view() => MaterialApp(
      home: Scaffold(
        body: SettingsView(
          settings: {
            'language': 'auto',
            'look': 'adwaita',
            'map_layers': const ['agents'],
            'flutter_map_layout': layout,
          },
          busy: false,
          tr: (key) => key,
          onBack: () {},
          onUpdate: (values) async {},
          onMapLayout: (change) => layout = change(layout),
        ),
      ),
    );
    await tester.pumpWidget(view());
    final toggle = find.byKey(const ValueKey('card-border'));
    await tester.scrollUntilVisible(
      toggle,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('card-border-width-1')), findsNothing);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpWidget(view());
    expect(layout['card_border'], {'on': true});
    final red = find.byKey(const ValueKey('card-border-color-#ef5350'));
    await tester.ensureVisible(red);
    await tester.pumpAndSettle();
    await tester.tap(red);
    expect(layout['card_border'], {'on': true, 'color': '#ef5350'});
    final theme = find.byKey(const ValueKey('card-border-color-theme:primary'));
    await tester.ensureVisible(theme);
    await tester.pumpAndSettle();
    await tester.tap(theme);
    expect(layout['card_border'], {'on': true, 'color': 'theme:primary'});
    final line = find.byKey(const ValueKey('line-color-mcp-#66bb6a'));
    await tester.ensureVisible(line);
    await tester.pumpAndSettle();
    await tester.tap(line);
    expect(layout['line_colors'], {'mcp': '#66bb6a'});
    await tester.pumpWidget(view());
    final back = find.byKey(const ValueKey('line-color-mcp-default'));
    await tester.ensureVisible(back);
    await tester.pumpAndSettle();
    await tester.tap(back);
    expect(layout['line_colors'], <String, dynamic>{});

    // A width changed elsewhere shows while Settings stays open.
    layout = {
      'card_border': {'on': true, 'width': 5},
    };
    await tester.pumpWidget(view());
    await tester.scrollUntilVisible(
      find.text('5 px'),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('5 px'), findsOneWidget);
  });

  testWidgets('column widths: shown, kept with the layout, not lost on Back', (
    tester,
  ) async {
    var layout = <String, dynamic>{
      'pins': ['agent:a'],
      'column_widths': {'agents': 410},
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
              'flutter_map_layout': {
                'pins': ['agent:a'],
                'column_widths': {'agents': 410},
              },
            },
            busy: false,
            tr: (key) => key,
            onBack: () {},
            onUpdate: (values) async {},
            onMapLayout: (change) => layout = change(layout),
          ),
        ),
      ),
    );
    final current = find.byKey(const ValueKey('column_widths-agents'));
    final fallback = find.byKey(const ValueKey('column_defaults-agents'));
    await tester.scrollUntilVisible(
      fallback,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: current, matching: find.text('410')),
      findsOneWidget,
    );

    await tester.enterText(fallback, '5000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(layout['pins'], ['agent:a']);
    expect(layout['column_defaults'], {'agents': 900});

    await tester.enterText(current, '360');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // Each field changes only its own value, so nothing goes back.
    expect(layout['column_widths'], {'agents': 360});
    expect(layout['column_defaults'], {'agents': 900});
  });

  testWidgets('manual mode and independent scan targets are editable', (
    tester,
  ) async {
    Map<String, dynamic>? updated;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
              'map_scan_interval': 0,
              'map_scan_pause_unfocused': true,
              'map_scan_targets': ['activity'],
            },
            busy: false,
            tr: (key) => key,
            onBack: () {},
            onUpdate: (values) async {
              updated = values;
            },
          ),
        ),
      ),
    );
    // Down to the last target this test uses: the list builds only what it shows.
    await tester.scrollUntilVisible(find.text('Agent details'), 250);
    final activity = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Activity and subagents'),
    );
    final agents = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Agent details'),
    );
    expect(activity.value, isTrue);
    expect(agents.value, isFalse);
    agents.onChanged!(true);
    expect(updated, {
      'map_scan_targets': ['activity', 'agents'],
    });
    await tester.scrollUntilVisible(
      find.text('Pause scans while unfocused'),
      -200,
    );
    final pause = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Pause scans while unfocused'),
    );
    expect(pause.value, isTrue);
    pause.onChanged!(false);
    expect(updated, {'map_scan_pause_unfocused': false});
  });
}
