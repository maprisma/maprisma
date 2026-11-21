import 'package:maprisma_core/src/core_tasks.dart';
import 'package:maprisma_core/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  // The registry is per process: each test starts from an empty one.
  setUp(resetHandlesForTest);
  tearDown(() {
    recordReleasedHandles = false;
    resetHandlesForTest();
  });

  test('a kept handle outlives any number of later handles', () {
    final undos = HandleMap<String>();
    final kept = newHandle();
    undos[kept] = 'backup';
    final dropped = newHandle();
    // More than the registry's bound, none of them kept.
    for (var i = 0; i < maxIssuedHandles + 100; i++) {
      newHandle();
    }
    expect(issuedHandle(kept), isTrue);
    expect(heldHandle(kept), isTrue);
    expect(issuedHandle(dropped), isFalse);
    // Once its store lets go, it stops counting at once.
    undos.remove(kept);
    expect(heldHandle(kept), isFalse);
    expect(issuedHandle(kept), isFalse);
  });

  test('a released handle is not revived by a result that still names it', () {
    final drafts = HandleMap<int>();
    final draft = newHandle();
    drafts[draft] = 1;
    final cached = {'draft_id': draft};
    expect(issuedHandlesIn(cached), {draft});
    drafts.remove(draft);
    expect(issuedHandlesIn(cached), isEmpty);
  });

  test('a handle moved from one store to another stays valid', () {
    final previews = HandleMap<int>(), plans = HandleMap<int>();
    final token = newHandle();
    previews[token] = 1;
    previews.remove(token);
    plans[token] = 2;
    expect(issuedHandle(token), isTrue);
    plans.clear();
    expect(issuedHandle(token), isFalse);
  });

  test('bare keys count too, and a key kept twice needs both releases', () {
    final first = HandleMap<int>(), second = HandleMap<int>();
    final token = newHandle().substring(coreHandle.length);
    first[token] = 1;
    second['$coreHandle$token'] = 2;
    first.removeWhere((_, _) => true);
    expect(heldHandle(token), isTrue);
    expect(issuedHandle(token), isTrue);
    second.clear();
    expect(heldHandle(token), isFalse);
  });

  test('when every handle is still kept, a new one is refused', () {
    final store = HandleMap<int>();
    for (var i = 0; i < maxIssuedHandles; i++) {
      store[newHandle()] = i;
    }
    final kept = store.keys.first;
    expect(
      newHandle,
      throwsA(
        isA<ServiceError>().having((e) => e.code, 'code', 'too_many_handles'),
      ),
    );
    expect(issuedHandle(kept), isTrue);
    // One store letting go makes room again.
    store.remove(kept);
    expect(newHandle(), startsWith(coreHandle));
  });

  test('a feature backend lists what its stores released, once', () {
    recordReleasedHandles = true;
    final previews = HandleMap<int>();
    final token = newHandle();
    final bare = token.substring(coreHandle.length);
    previews[token] = 1;
    expect(takeReleasedHandles(), isEmpty);
    previews.remove(token);
    expect(takeReleasedHandles(), [bare]);
    // Later sweeps do not list it again.
    for (var i = 0; i < maxIssuedHandles + 10; i++) {
      newHandle();
    }
    expect(takeReleasedHandles(1 << 20), isNot(contains(bare)));
  });

  test('a moved handle is not reported as released', () {
    recordReleasedHandles = true;
    final previews = HandleMap<int>(), plans = HandleMap<int>();
    final token = newHandle();
    previews[token] = 1;
    previews.remove(token);
    plans[token] = 2;
    expect(takeReleasedHandles(), isNot(contains(token.substring(5))));
  });

  test('a moved handle comes back within the bound', () {
    final first = HandleMap<int>(), second = HandleMap<int>();
    final token = newHandle();
    first[token] = 1;
    while (issuedHandleCountForTest < maxIssuedHandles) {
      newHandle();
    }
    first.remove(token);
    newHandle();
    second[token] = 2;
    expect(issuedHandle(token), isTrue);
    expect(issuedHandleCountForTest, lessThanOrEqualTo(maxIssuedHandles));
  });

  test('a move into a full registry is refused as a whole', () {
    final first = HandleMap<int>(), full = HandleMap<int>();
    final second = HandleMap<int>();
    final token = newHandle();
    first[token] = 1;
    while (issuedHandleCountForTest < maxIssuedHandles) {
      full[newHandle()] = 0;
    }
    first.remove(token);
    full[newHandle()] = 0;
    expect(
      () => second[token] = 2,
      throwsA(
        isA<ServiceError>().having((e) => e.code, 'code', 'too_many_handles'),
      ),
    );
    expect(second.containsKey(token), isFalse);
    expect(heldHandle(token), isFalse);
    expect(issuedHandle(token), isFalse);
  });
}
