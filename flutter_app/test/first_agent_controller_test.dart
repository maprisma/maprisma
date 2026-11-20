import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/first_agent_controller.dart';

const original = <String, dynamic>{
  'routes': [
    {'id': 'online', 'title': 'Online', 'access': 'An account'},
    {'id': 'local', 'title': 'Local', 'access': 'This PC'},
  ],
  'selected': 'online',
};

void main() {
  test(
    'delayed check shows progress and publishes only a completed snapshot',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final guide = FirstAgentController(
        read: () => pending.future,
        saveChoice: (_) async {},
      );
      addTearDown(guide.dispose);
      final operation = guide.refresh();
      expect(guide.loading, isTrue);
      expect(guide.data, isEmpty);
      pending.complete(original);
      await operation;
      expect(guide.loading, isFalse);
      expect(guide.data, original);
      expect(guide.errorKey, isNull);
    },
  );

  test(
    'failed refresh retains the checklist and retries only on request',
    () async {
      var calls = 0;
      final guide = FirstAgentController(
        read: () async {
          calls++;
          if (calls == 2) throw StateError('fixture read failure');
          return original;
        },
        saveChoice: (_) async {},
      );
      addTearDown(guide.dispose);
      await guide.refresh();
      await guide.refresh();
      expect(guide.data, original);
      expect(guide.errorKey, contains('could not be checked'));
      expect(calls, 2);
      await guide.retry();
      expect(calls, 3);
      expect(guide.errorKey, isNull);
    },
  );

  test(
    'failed choice keeps the confirmed route and retry saves the intended route',
    () async {
      final choices = <String>[];
      var reads = 0;
      final guide = FirstAgentController(
        read: () async {
          reads++;
          return choices.length > 1
              ? {...original, 'selected': 'local'}
              : original;
        },
        saveChoice: (route) async {
          choices.add(route);
          if (choices.length == 1) throw StateError('fixture save failure');
        },
      );
      addTearDown(guide.dispose);
      await guide.refresh();
      await guide.choose('local');
      expect(guide.data['selected'], 'online');
      expect(guide.errorKey, contains('could not be saved'));
      expect(reads, 1);
      await guide.retry();
      expect(choices, ['local', 'local']);
      expect(reads, 2);
      expect(guide.data['selected'], 'local');
    },
  );

  test(
    'saved choice survives failed refresh without repeating the save',
    () async {
      var reads = 0, saves = 0;
      final guide = FirstAgentController(
        read: () async {
          reads++;
          if (reads == 2) throw StateError('fixture check failure');
          return reads > 2 ? {...original, 'selected': 'local'} : original;
        },
        saveChoice: (_) async {
          saves++;
        },
      );
      addTearDown(guide.dispose);
      await guide.refresh();
      await guide.choose('local');
      expect(guide.data['selected'], 'local');
      expect(guide.data['routes'], original['routes']);
      expect(guide.errorKey, contains('could not be checked'));
      await guide.retry();
      expect(saves, 1);
      expect(guide.errorKey, isNull);
    },
  );

  test('pending check blocks duplicate refresh and route selection', () async {
    var reads = 0, saves = 0;
    final pending = Completer<Map<String, dynamic>>();
    final guide = FirstAgentController(
      read: () {
        reads++;
        return pending.future;
      },
      saveChoice: (_) async {
        saves++;
      },
    );
    addTearDown(guide.dispose);
    final first = guide.refresh();
    await guide.refresh();
    await guide.choose('local');
    await guide.retry();
    expect(reads, 1);
    expect(saves, 0);
    pending.complete(original);
    await first;
  });

  test('leaving and reopening ignores the earlier late read', () async {
    final old = Completer<Map<String, dynamic>>();
    var reads = 0;
    final guide = FirstAgentController(
      read: () => ++reads == 1
          ? old.future
          : Future.value({...original, 'selected': 'local'}),
      saveChoice: (_) async {},
    );
    addTearDown(guide.dispose);
    final first = guide.refresh();
    guide.cancelPending();
    await guide.refresh();
    old.complete(original);
    await first;
    expect(guide.data['selected'], 'local');
    expect(guide.loading, isFalse);
    expect(guide.errorKey, isNull);
  });

  test('reopening can replace a read still running on another page', () async {
    final old = Completer<Map<String, dynamic>>();
    var reads = 0;
    final guide = FirstAgentController(
      read: () => ++reads == 1
          ? old.future
          : Future.value({...original, 'selected': 'local'}),
      saveChoice: (_) async {},
    );
    addTearDown(guide.dispose);
    final first = guide.refresh();
    await guide.refresh(replace: true);
    old.completeError(StateError('old failed read'));
    await first;
    expect(guide.data['selected'], 'local');
    expect(guide.errorKey, isNull);
  });

  test(
    'invalid snapshot is a failed check rather than an empty catalog',
    () async {
      var reads = 0;
      final guide = FirstAgentController(
        read: () async => ++reads == 1 ? original : {'ok': true},
        saveChoice: (_) async {},
      );
      addTearDown(guide.dispose);
      await guide.refresh();
      await guide.refresh();
      expect(guide.data, original);
      expect(guide.errorKey, contains('could not be checked'));
    },
  );

  test('rows the view could not show are a failed check', () {
    Map<String, dynamic> withStep(
      Map<String, dynamic> step, {
      Object? command = 'agent',
    }) => {
      'routes': [
        {
          'id': 'online',
          'title': 'Online',
          'access': 'An account',
          'command': ?command,
          'steps': [step],
        },
      ],
    };
    const ok = {
      'title': 'Sign in',
      'done': false,
      'detail': '',
      'action': 'login',
    };
    expect(validGuideSnapshot(original), isTrue);
    expect(validGuideSnapshot(withStep(ok)), isTrue);
    expect(validGuideSnapshot({'ok': true}), isFalse);
    expect(
      validGuideSnapshot({
        'routes': [
          {'id': 'x', 'title': 3, 'access': ''},
        ],
      }),
      isFalse,
    );
    expect(validGuideSnapshot(withStep({...ok, 'detail': null})), isFalse);
    expect(
      validGuideSnapshot(withStep(ok, command: null)),
      isFalse,
      reason: 'its button needs the command',
    );
    expect(
      validGuideSnapshot(withStep({...ok, 'action': 'install-tool'})),
      isFalse,
      reason: 'no target',
    );
    expect(
      validGuideSnapshot(
        withStep({
          ...ok,
          'action': 'install-tool',
          'target': 'mise',
        }, command: null),
      ),
      isTrue,
    );
    expect(
      validGuideSnapshot(
        withStep({...ok, 'action': 'download-starter', 'target': 'ollama'}),
      ),
      isFalse,
      reason: 'no starter',
    );
    expect(validGuideSnapshot({...original, 'answer': 4}), isFalse);
  });

  test(
    'a malformed row keeps the last snapshot and says it could not be checked',
    () async {
      var reads = 0;
      final guide = FirstAgentController(
        read: () async => ++reads == 1
            ? original
            : {
                'routes': [
                  {
                    'id': 'online',
                    'title': 'Online',
                    'access': 'An account',
                    'steps': [
                      {'title': 'x'},
                    ],
                  },
                ],
              },
        saveChoice: (_) async {},
      );
      addTearDown(guide.dispose);
      await guide.refresh();
      await guide.refresh();
      expect(guide.data, original);
      expect(guide.errorKey, contains('could not be checked'));
    },
  );

  test(
    'a failed refresh after a failed save still says the choice is unsaved',
    () async {
      var readFails = false;
      final saved = <String>[];
      var saveFails = true;
      final guide = FirstAgentController(
        read: () async => readFails ? throw StateError('no') : original,
        saveChoice: (route) async {
          if (saveFails) throw StateError('no');
          saved.add(route);
        },
      );
      addTearDown(guide.dispose);
      await guide.choose('local');
      readFails = true;
      await guide.refresh();
      expect(guide.choiceFailed, isTrue);
      expect(guide.errorKey, contains('could not be saved'));
      readFails = false;
      saveFails = false;
      await guide.retry();
      expect(saved, ['local']);
      expect(guide.errorKey, isNull);
    },
  );

  test('a read that timed out, was replaced or was left is stopped', () async {
    var abandoned = 0;
    final guide = FirstAgentController(
      read: () => Completer<Map<String, dynamic>>().future,
      saveChoice: (_) => Completer<void>().future,
      abandonRead: () => abandoned++,
      timeout: const Duration(milliseconds: 20),
    );
    await guide.refresh();
    expect(abandoned, 1); // timed out
    unawaited(guide.refresh());
    unawaited(guide.refresh(replace: true));
    expect(abandoned, 2); // replaced while running
    guide.cancelPending();
    expect(abandoned, 3); // left
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(abandoned, 3); // the left reads' late timeouts stop nothing
    guide.cancelPending();
    expect(abandoned, 3); // nothing running: nothing to stop
    final saveAbandoned = abandoned;
    await guide.choose('online');
    expect(abandoned, saveAbandoned); // a hung save started no read
    unawaited(guide.refresh());
    guide.dispose();
    expect(abandoned, saveAbandoned + 1);
  });

  test('a hung check or save ends as a failed one with Retry', () async {
    final never = Completer<Map<String, dynamic>>();
    final guide = FirstAgentController(
      read: () => never.future,
      saveChoice: (_) => Completer<void>().future,
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(guide.dispose);
    await guide.refresh();
    expect(guide.loading, isFalse);
    expect(guide.errorKey, contains('could not be checked'));
    await guide.choose('online');
    expect(guide.loading, isFalse);
    expect(guide.choiceFailed, isTrue);
    expect(guide.errorKey, contains('could not be saved'));
  });

  test(
    'refresh after a failed save keeps the unsaved choice and its Retry',
    () async {
      var fail = true;
      final saved = <String>[];
      final guide = FirstAgentController(
        read: () async => original,
        saveChoice: (route) async {
          if (fail) throw StateError('no');
          saved.add(route);
        },
      );
      addTearDown(guide.dispose);
      await guide.choose('local');
      expect(guide.choiceFailed, isTrue);
      await guide.refresh();
      expect(guide.choiceFailed, isTrue, reason: 'not dropped without a word');
      expect(guide.errorKey, contains('could not be saved'));
      expect(
        guide.data['selected'],
        'online',
        reason: 'the confirmed choice is still shown',
      );
      fail = false;
      await guide.retry();
      expect(saved, ['local']);
      expect(guide.choiceFailed, isFalse);
      // a new open of the guide starts over
      fail = true;
      await guide.choose('online');
      await guide.refresh(replace: true);
      expect(guide.choiceFailed, isFalse);
    },
  );

  test(
    'leaving while a choice is being saved ignores its late result',
    () async {
      final save = Completer<void>();
      var reads = 0;
      final guide = FirstAgentController(
        read: () async {
          reads++;
          return original;
        },
        saveChoice: (_) => save.future,
      );
      addTearDown(guide.dispose);
      final choosing = guide.choose('local');
      expect(guide.loading, isTrue);
      guide.cancelPending();
      expect(guide.loading, isFalse);
      save.complete();
      await choosing;
      expect(
        guide.data,
        isEmpty,
        reason: 'no selection from an abandoned save',
      );
      expect(reads, 0, reason: 'no check after it either');
      expect(guide.errorKey, isNull);
    },
  );

  test('disposed controller ignores late completion', () async {
    final pending = Completer<Map<String, dynamic>>();
    final guide = FirstAgentController(
      read: () => pending.future,
      saveChoice: (_) async {},
    );
    var changes = 0;
    guide.addListener(() => changes++);
    final operation = guide.refresh();
    guide.dispose();
    pending.complete(original);
    await operation;
    expect(changes, 1);
    expect(guide.data, isEmpty);
  });
}
