import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/usage_sweep.dart';

/// Review 063, round 2 #15: the batteries' usage records are renewed while
/// the map is open, each agent at most every ten minutes, one sweep at a
/// time, without waiting for an agent's details.
void main() {
  test('each agent at most every ten minutes, one after the other', () async {
    var now = DateTime(2026, 11, 5, 12);
    final sweep = UsageSweep(now: () => now);
    final asked = <String>[];
    Future<bool> ask(String command) async {
      asked.add(command);
      return command == 'codex';
    }

    expect(await sweep.sweep(['codex', 'claude'], ask), isTrue);
    expect(asked, ['codex', 'claude']);
    now = now.add(const Duration(minutes: 9, seconds: 59));
    expect(await sweep.sweep(['codex', 'claude'], ask), isFalse);
    expect(asked, hasLength(2)); // not due yet
    now = now.add(const Duration(seconds: 1));
    expect(await sweep.sweep(['codex', 'claude'], ask), isTrue);
    expect(asked, ['codex', 'claude', 'codex', 'claude']);
    // An agent's details asked on their own count too.
    now = now.add(const Duration(minutes: 10));
    expect(sweep.take('codex'), isTrue);
    await sweep.sweep(['codex', 'claude'], ask);
    expect(asked.last, 'claude');
    expect(asked.where((c) => c == 'codex'), hasLength(2));
  });

  test('one sweep at a time, and a failed one does not stop it', () async {
    final sweep = UsageSweep();
    final gate = Completer<bool>();
    final asked = <String>[];
    final first = sweep.sweep(['codex', 'gemini'], (command) {
      asked.add(command);
      if (command == 'codex') return gate.future;
      throw StateError('no answer');
    });
    expect(sweep.running, isTrue);
    expect(await sweep.sweep(['claude'], (c) async => true), isFalse);
    gate.complete(false);
    expect(await first, isFalse);
    expect(asked, ['codex', 'gemini']);
    expect(sweep.running, isFalse);
    expect(await sweep.sweep(['claude'], (c) async => true), isTrue);
  });
}
