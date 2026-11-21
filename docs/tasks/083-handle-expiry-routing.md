# 083 Handle routing follows each store's expiry

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/083-handle-expiry-routing

Follow-up of task 082's review finding R5-C3, accepted there as a known limit (Uwe, 2026-11-21).

## Goal
A handle that its store still keeps (an Undo backup, a preview, a feature worker's handle)
stays usable however many other handles were issued after it. Today the issued-handle set
(`core_tasks.dart`, `maxIssuedHandles` = 65,536) and the feature-plugin owner map
(`feature_plugins.dart`, `_owners`) forget the oldest handles by count, so after 65,536 later
handles an Undo whose backup is still kept is refused (safely: it never reaches the wrong
process).

## Routes
None. The handle shape and every route's params and results stay as they are.

## Core
- Provenance and routing (`issuedHandle`, `issuedHandlesIn`, the feature owner map) forget a
  handle when its owning store expires or drops it, not by a global count.
- Each handle store (Undo, previews, plan/feature workers, ...) tells the registry when a
  handle ends; a worker that exits releases all of its handles.
- A hard upper bound stays as a memory guard; reaching it refuses new handles with a clear
  error instead of evicting live ones.

## UI
None.

## Acceptance
- A test keeps one Undo handle while issuing more than 65,536 other, expiring handles; the
  Undo still routes and works. The test fails without the fix.
- A handle whose store expired it is refused, as today.
- A feature worker's exit releases its handles from the owner map.
- `tools/test-changed` green; complete suites at the end; Codex and agy review CLEAN.
