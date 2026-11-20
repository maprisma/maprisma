import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/first_agent_view.dart';

const route = <String, dynamic>{
  'id': 'fixture',
  'kind': 'online',
  'title': 'Fixture route',
  'access': 'Fixture access',
  'command': 'fixture',
  'verified': false,
  'steps': [
    {'title': 'Install fixture', 'done': true, 'detail': '', 'action': ''},
    {
      'title': 'A test question',
      'done': false,
      'detail': 'Ask one question.',
      'action': 'verify',
    },
  ],
};
const snapshot = <String, dynamic>{
  'routes': [route],
  'selected': 'fixture',
};

void main() {
  Widget view({
    Map<String, dynamic> data = const {},
    bool loading = false,
    String? errorKey,
    VoidCallback? onRetry,
    VoidCallback? onFinish,
    void Function(String, String)? onAction,
    Map<String, dynamic> translations = const {},
    double scale = 1,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: FirstAgentView(
        data: data,
        busy: false,
        loading: loading,
        errorKey: errorKey,
        onRetry: onRetry,
        onFinish: onFinish,
        tr: (key) => translations[key] as String? ?? key,
        onChoose: (_) {},
        onAction: onAction ?? (_, _) {},
        onBack: () {},
        onRefresh: () {},
      ),
    ),
  );

  testWidgets(
    'loading is distinct from empty choices and disables setup actions',
    (tester) async {
      await tester.pumpWidget(view(loading: true));
      expect(find.text('Checking your setup…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('No setup options'), findsNothing);
      for (final label in ['Find existing AI', 'Add-ons']) {
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, label),
              )
              .onPressed,
          isNull,
        );
      }
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Refresh'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'failed check keeps the selected checklist and exposes explicit retry',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        view(
          data: snapshot,
          errorKey:
              'Your setup could not be checked. Your last choices are kept.',
          onRetry: () => retries++,
        ),
      );
      expect(find.text('Fixture route'), findsOneWidget);
      expect(find.text('Next step: A test question'), findsOneWidget);
      expect(find.textContaining('No setup options'), findsNothing);
      expect(retries, 0);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);
    },
  );

  testWidgets('failed first check does not claim an empty catalog', (
    tester,
  ) async {
    await tester.pumpWidget(
      view(
        errorKey:
            'Your setup could not be checked. Your last choices are kept.',
      ),
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('No setup options'), findsNothing);
    expect(find.text('With an online account'), findsNothing);
    expect(find.text('On this PC'), findsNothing);
  });

  testWidgets(
    'empty choices explain recovery through existing discovery or add-ons',
    (tester) async {
      final actions = <String>[];
      await tester.pumpWidget(
        view(
          data: const {'routes': []},
          onAction: (_, action) => actions.add(action),
        ),
      );
      expect(find.textContaining('No setup options'), findsOneWidget);
      expect(find.text('With an online account'), findsNothing);
      expect(find.text('On this PC'), findsNothing);
      await tester.tap(find.text('Add-ons'));
      await tester.tap(find.text('Find existing AI'));
      expect(actions, ['addons', 'existing']);
    },
  );

  testWidgets(
    'missing saved route is explained while available choices remain selectable',
    (tester) async {
      await tester.pumpWidget(
        view(
          data: {
            'routes': [route],
            'selected': 'removed',
          },
        ),
      );
      expect(find.textContaining('Your previous setup choice'), findsOneWidget);
      expect(find.text('Fixture route'), findsOneWidget);
      expect(find.text('With an online account'), findsOneWidget);
      expect(find.text('On this PC'), findsNothing);
    },
  );

  testWidgets(
    'manual prerequisites remain visible despite historical verification',
    (tester) async {
      await tester.pumpWidget(
        view(
          data: {
            'routes': [
              {
                ...route,
                'verified': true,
                'steps': [
                  {
                    'title': 'Sign in',
                    'done': false,
                    'detail': 'Use the account settings.',
                    'action': '',
                  },
                  {
                    'title': 'A test question',
                    'done': true,
                    'detail': '',
                    'action': 'verify',
                  },
                ],
              },
            ],
            'selected': 'fixture',
          },
          onFinish: () {},
        ),
      );
      expect(find.text('Next step: Sign in'), findsOneWidget);
      expect(find.text('Use the account settings.'), findsOneWidget);
      expect(
        find.textContaining('This step needs manual setup'),
        findsOneWidget,
      );
      expect(find.text('Your agent is ready'), findsNothing);
      expect(find.text('Open AI map'), findsNothing);
    },
  );

  testWidgets('steps waiting for an earlier step are not called manual setup', (
    tester,
  ) async {
    await tester.pumpWidget(
      view(
        data: {
          'routes': [
            {
              ...route,
              'steps': [
                {
                  'title': 'Fixture agent',
                  'done': false,
                  'detail': '',
                  'action': 'install',
                },
                {'title': 'Sign in', 'done': false, 'detail': '', 'action': ''},
                {
                  'title': 'A test question',
                  'done': false,
                  'detail': '',
                  'action': '',
                },
              ],
            },
          ],
          'selected': 'fixture',
        },
      ),
    );
    expect(find.text('Next step: Fixture agent'), findsOneWidget);
    expect(find.textContaining('This step needs manual setup'), findsNothing);
  });

  testWidgets('malformed saved route does not prevent choosing a route', (
    tester,
  ) async {
    await tester.pumpWidget(
      view(
        data: {
          'routes': [route],
          'selected': 42,
        },
      ),
    );
    expect(find.textContaining('Your previous setup choice'), findsOneWidget);
    expect(find.text('Fixture route'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'verification is explicit and a complete checked route can open the map',
    (tester) async {
      final actions = <String>[];
      var finished = 0;
      await tester.pumpWidget(
        view(data: snapshot, onAction: (_, action) => actions.add(action)),
      );
      expect(actions, isEmpty);
      await tester.ensureVisible(find.text('Send the test question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send the test question'));
      expect(actions, ['verify']);
      await tester.pumpWidget(
        view(
          data: {
            'routes': [
              {
                ...route,
                'verified': true,
                'steps': [
                  {
                    'title': 'A test question',
                    'done': true,
                    'detail': '',
                    'action': 'verify',
                  },
                ],
              },
            ],
            'selected': 'fixture',
          },
          onFinish: () => finished++,
        ),
      );
      expect(find.text('Your agent is ready'), findsOneWidget);
      await tester.ensureVisible(find.text('Open AI map'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open AI map'));
      expect(finished, 1);
      expect(actions, ['verify']);
    },
  );

  for (final language in ['de', 'pl']) {
    final translations =
        jsonDecode(File('../translations/$language.json').readAsStringSync())
            as Map<String, dynamic>;
    for (final scale in [1.5, 2.0]) {
      testWidgets('compact $language recovery states fit at $scale text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(540, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final data in <Map<String, dynamic>>[
          const {'routes': []},
          snapshot,
          {
            'routes': [
              {
                ...route,
                'steps': [
                  {
                    'title': 'Missing tool',
                    'done': false,
                    'detail': 'Set up the required program.',
                    'action': '',
                  },
                ],
              },
            ],
            'selected': 'fixture',
          },
        ]) {
          await tester.pumpWidget(
            view(data: data, translations: translations, scale: scale),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(find.byType(ListView), const Offset(0, -500));
          await tester.pumpAndSettle();
          if (data['selected'] != null) {
            final target = identical(data, snapshot)
                ? find.text(
                    translations['Send the test question'] as String? ??
                        'Send the test question',
                  )
                : find.text(
                    translations['This step needs manual setup. Follow its details, then refresh or check its add-on.']
                        as String,
                  );
            await tester.scrollUntilVisible(
              target,
              150,
              scrollable: find.byType(Scrollable).last,
            );
            await tester.pumpAndSettle();
            expect(target, findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
