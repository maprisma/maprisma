# 002 A typed client for the GUI

Author: Antigravity · Reviewer: Claude · Branch: task/002-typed-client

Read `AGENTS.md` first (above all "Working together") and `docs/protocol.md`.

## Goal
The GUI calls the core through a generated, typed client instead of route names as strings: a renamed or
removed route, or a missing parameter, then fails when the app is compiled, not when a user clicks.

## Routes
None changed. `routes.json` stays as it is (do not edit routes by hand in this task).

## What to build
1. `tools/protocol.py client` writes `flutter_app/lib/core_client.g.dart` from `routes.json`
   (`update` and `doc` keep working; `update` also rewrites the client):
   - `class CoreClient` around the existing `ServiceTransport` (`flutter_app/lib/service_transport.dart`).
   - One method per route, named in lowerCamelCase from the route (`agents.details` → `agentsDetails`,
     `connections.repair_preview` → `connectionsRepairPreview`), returning `Future<Map<String, dynamic>>`.
   - Parameters as named arguments from the route's `params`: `string` → `String`, `int` → `int`, `bool` →
     `bool`, `number` → `num`, anything else (`?`, maps, lists) → `Object?`. All `required` except where the
     GUI today sometimes leaves one out: then nullable and only sent when given. Keep the parameter names as the
     core expects them (`snake_case` keys in the map, lowerCamelCase argument names).
   - Handle routes take their handle (`plan`, `undo`, `task`, `session`) as a required `String`.
   - A header comment: generated, do not edit, made by `tools/protocol.py client`.
2. The GUI (`flutter_app/lib/*.dart`) uses the client for every call whose route name is written in the code.
   Calls whose route is chosen at run time (a `method` variable: `main.dart`, `health_card.dart`, task dialogs)
   stay on `call(method, params)`; leave them and list them in the task's review request.
3. `tools/protocol.py check` also fails when `core_client.g.dart` is not what `client` would write, and when a
   file in `flutter_app/lib` other than the client calls `.call('<route>'` with a literal route name.
   `tests/test_protocol.py` covers both (a test that a literal call is caught, like
   `test_a_route_outside_the_contract_is_caught`).

## UI
No visible change. No new texts.

## Acceptance
- `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check`, `python3 -m unittest discover -s tests -q` and
  `UV_OFFLINE=1 tools/typecheck.sh` green.
- `grep -rn "\.call('[a-z]" flutter_app/lib --include=*.dart | grep -v core_client.g.dart` prints nothing.
- The app behaves exactly as before (widget tests unchanged and green).
- Commits: `protocol: …` (generator + check + tests), then `gui: …` (the switch to the client).
