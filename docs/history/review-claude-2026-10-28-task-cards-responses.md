# Responses to Claude's task-card review — 2026-10-28

Review: [review-claude-2026-10-28-task-cards.md](review-claude-2026-10-28-task-cards.md).
All seven findings, including all three smaller points in item 7, are addressed.
Changes are confined to the Flutter working tree and its documentation/manuals.

## 1. Forced scans and duplicate refresh — fixed

`_runTask` owns completion refresh for worker operations. Data-only operations
(`models.search`, `models.files`, `addons.catalog`, guide/discovery/check/preview
reads) skip inventory refresh entirely. Mutations refresh their view metadata
once and force a graph scan only when the task has a half map actually visible:
known focus nodes, half width, and at least 900 logical pixels of available width.
A full card or a narrow/unknown-focus fallback does not force a map scan.

`_refresh` no longer scans merely because `_card` or `_view` exists. The extra
completion refreshes in `_providerOperation`, `_removeModel` and queued connection
callers are removed. Synchronous connection changes keep their own single
completion refresh. Result Undo similarly has one graph-refresh owner.

The subprocess-backed app tests record actual service requests: search and file
listing produce no `app.snapshot` or forced map refresh; model load and queued
connection apply each produce exactly one forced scan. The refreshed connection
edge reaches the result's task map.

## 2. Duplicate headers and fixed model-browser size — fixed

ConnectionsView, ProvidersView, FirstAgentView, MapAddonsFocus/MapFocus and
ModelBrowser now accept a `hosted` flag, enabled by the application. Hosted views
omit their own heading and Back/Close controls; TaskHost owns those controls.
The group card uses the category's heading. Connections Undo and guide Refresh
remain available as secondary actions. Standalone views retain their existing
headers by default.

Hosted ModelBrowser fills the card instead of retaining its 760 × 620 size and
second close button. Widget tests check a single heading/Back, retained Undo and
Refresh actions, and a browser body wider than 1000 and taller than 620 pixels.

## 3. Lost state below reviews/progress — fixed

Task views stay mounted in a keyed `RetainedTaskView` while a card overlays them.
It uses Offstage, ExcludeFocus and TickerMode so hidden views cannot steal focus
or keep ticking. This retention condition covers task views only: the main AI
map is still not built behind a task card. ModelBrowser and System Map retain
their existing state-preservation paths.

Stable body keys also preserve state when the host switches between half/full
layouts. Connections owns its search controller and keys connection cards;
adding the Undo row after Apply therefore preserves the visible search text and
expanded server. App-level tests check the search after both Cancel and Apply,
and check that a welcome checkbox manually deselected by the user remains
unticked after catalog progress and a cancelled installation review.

## 4. ProvidersView width/focus — fixed by making the overview explicitly full

ProvidersView lists all runtimes and has no runtime selection. It now requests a
full card explicitly, and the unused top-level `_focusOf(_providers)` read is
removed. The plan's width table and all eight manual translations now describe
this choice. Individual runtime actions still use the service's per-runtime
`focus` metadata for their half-card review/progress maps.

## 5. Live updates behind idle results/model browsing — fixed

`_refreshLive` pauses for running work, a waiting review, or a nonclosable phase.
An idle result card or model browser follows the normal interval-based metadata
refresh path, even when its underlying route is Providers/Connections. These
updates do not force scans and retain the Manual-only, interval and window-focus
rules.

Header controls now use the actual task/review/busy guard instead of disabling
all navigation whenever `_card` is non-null. A finished result allows Refresh,
Map and Settings navigation; navigation dismisses the result/browser when
appropriate. App tests observe fresh non-forced map requests while a result and
then the model browser remain open, and check that result Refresh is enabled.

## 6. Task-map vertical alignment — fixed

Read-only AgentMap uses the compact `rows * 106 + 170` height. The normal map
keeps its 650-pixel minimum. The read-only map test now checks the one-row
276-pixel canvas, alongside its interaction and anchor-painter checks.

## 7. Smaller points — all fixed

- **Review counting:** `_cardReview` is the sole `_review` wrapper for card
  reviews. Redundant wrappers at add-on removal/install and agent-action call
  sites are removed. Unrelated existing sheet/dialog review guards remain.
- **Catalog after install/failure:** `_installAddon` reloads the signed catalog
  after both successful and failed installations while the service is connected.
  `_reloadAddonCatalog` polls the existing catalog worker without replacing the
  task's result card, updates entries and their preview handles, then restores
  the card's closability. If the catalog reload itself fails, the existing retry
  UI and an error message remain available. App tests cover success and worker
  failure, verify a second catalog request and fresh preview handles, and verify
  that the result remains visible rather than reverting to “load catalog”.
- **First-result Undo:** `_runTask` registers returned Undo handles before
  building the result. The queued connection caller no longer builds a second
  result or refreshes again. Direct synchronous connections register their handle
  before their sole result. The app test checks that the connection result has
  Undo and the new graph edge.

## Validation

- `tools/flutter-dev check`: format unchanged, analyzer clean, **50 tests passed**.
- `python3 -m unittest discover -s tests -q`: **1,381 tests passed**, all modules.
- `UV_OFFLINE=1 tools/typecheck.sh`: **0 errors, 0 warnings**.
- `git diff --check`: clean.
- All eight manual PDFs rebuilt with Chromium/pdfcraft. Only the changed
  `task-cards` chapter was re-stamped in each translation. The pre-existing
  `about` / `running-agents` fingerprint drift is still reported; it is separate
  from this review and was not hidden by stamping unrelated sections.
- Dart transport checks: passed.
- Native Linux Devel build: succeeded, not launched. Preview:
  `/mnt/Data/Projects/asterism-flutter/.flutter-previews/preview-2tat19de/flutter_app/build/linux/x64/release/bundle/asterism`.

No real installer, download, model removal or add-on change was executed. No
physical desktop interaction, live application launch, commit, plugin sync or
publication was performed. Real-desktop appearance remains outside these checks,
as it was in Claude's review.
