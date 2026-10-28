# Map groups and add-ons — implementation responses

## Action inventory (before implementation)

| Existing surface/action | New home |
|---|---|
| Welcome Look at this PC / Skip; separate-mount and simplify hints | Welcome bar above AI Map; System Map link |
| Detected, premarked add-ons; Switch on / Later; pending/error/retry | First Agents focus, fixed footer; one batch Undo |
| Signed notice; online catalog preference and explicit fetch | Focus header |
| Installed enabled/disabled, unsupported/failed state | Focus On / Off / Found sections, Add-on details |
| Signed catalog Get / Update, preview and permissions | Focus Not installed / card menu, existing confirmation |
| GTK Update add-on to version, Add-on details Reads/Sends/May do | Card overflow/right-click menu, details dialog |
| GTK remove user add-on | Reviewed backed-up removal and Undo in details |
| GTK online-provider Sign in to agent | Provider add-on menu; registered agent sign-in preview |
| Agent map detail/start/lifecycle/subagents | Existing node actions retained, menu links to agent details |
| Providers and models download/import/pull/load/remove | Models/Providers focus links to existing Providers and models flow |
| Existing model-folder reuse and disk discovery | Models focus → System Map |
| MCP/skill connect/disconnect, preview/backup/Undo | MCP servers and skills focus → Connections |
| Setup/header navigation and add-on lists | Removed; expandable groups replace them |
| Unsupported feature/extension add-ons | Read-only provider-focus inventory, unsupported notice |

Gaps retained explicitly: creating a new MCP definition and adding/installing a new
skill folder have no existing Flutter flow. Catalog update checks require explicit
online consent. No new add-on kinds or unsigned installation are introduced.

Implementation and validation results follow below.

## 1–3. Group cards, dummies and focus

`map_groups.dart` defines UI-only `MapGroup`, reusable dashed group cards and
`MapFocus`. `agent_map.dart` positions one group above each column and retains
normal node/edge/drop behavior. Empty categories have no synthetic node IDs:
dummies never enter the graph, saved cache, AI facts, edge lists or drop targets.
Local found counts and signed-catalog availability are separate from real counts.

AI focus uses a finite 200 ms transition and leaves the transformation controller
and selection outside the focused child. Click Expand, double-click or keyboard
activation opens a group; Back, Esc, Backspace or the surrounding background
collapses it. Bare Super is ignored. Backspace remains available to text editing.
No animation runs while idle except an actual pending task’s progress.

`map_addons_focus.dart` provides applicable On / Off / Found / Not installed
sections. A dummy omits On/Off headings; locally available adapter metadata
remains reachable in the available section. Unsupported UI-feature metadata stays
read-only. The catalog is requested only from the explicit button, never from
expansion, startup or the online preference switch. The focus Refresh action
reruns local adapter detection without fetching the catalog. Disabling online access still
permits explicit cached-catalog browsing; install/update remains disabled.

## 4. Actions, guards and Undo

Normal map overflow/right-click actions and focus menus retain agent details and
the existing lifecycle controls. Signed add-on cards provide immediate switches,
permissions/capabilities, newer signed-catalog versions and provider sign-in using
installed registered agents. All execution still passes through the existing
reviewed installer/sign-in services. Catalog update entries appear only when the
verified service catalog reports a newer version and supplies a preview handle.

Each switch offers one Undo snackbar using the previous state. First-use switching
is one batch with one Undo. Backend guards protect switches, batch apply, install,
removal and removal Undo while owned or external registered agents run. A failed
enable reloads the previous adapter set and leaves saved choices unchanged.

`flutter_addon_actions.py` provides reviewed, backed-up removal of user add-ons.
Bundled add-ons stay managed by their package. Removal revalidates the original
folder identity, renames it into a private adjacent `addon-backups/` folder and
preserves unrelated enabled choices. Undo refuses occupied destination paths,
restores the original folder and re-verifies before restoring its enabled state.
Settings failures roll back the rename. The Undo handle lasts until the service
closes; backup bytes are retained. This is distinct from uninstalling an agent
program or deleting its data. All removal execution tests use temporary fixtures.

Review dialogs suppress idle progress indicators while waiting for consent;
backend task dialogs retain their actual operation progress. The earlier S1 fix
is preserved rather than weakening `pumpAndSettle` tests.

## 5–6. Welcome and removed pages

`map_welcome.dart` keeps Look at this PC / Skip, separate-mount/simplification
hints and a System Map link above the map. First use opens Agents focus with
detected agents marked, manual exclusions preserved and fixed Switch on / Later
controls. Detection pending disables Switch on. First-use batch selection concerns
agents; other already-enabled add-on kinds remain unchanged. Found runtimes can
be enabled separately through Providers. Later preserves saved choices and can
be used while agents run. Subsequent starts do not auto-expand.

Removed `setup_view.dart`, `addons_view.dart`, their navigation entries and
`_showSetup` / `_showAddons`. Local inventory/detection and every existing service
route remain. Their tests are replaced by group/focus tests; add-on installation
review tests are retained in `addon_details_test.dart`. System Map’s former Setup
button now opens map add-on management.

## 7. System Map

All five columns use the same group card/dummy and focus frame. Selecting a node
in the focused list returns to the existing System Map detail/actions panel.
Pan/zoom, selection, discovery/reconnect, model moves and AI consent remain with
their existing controls. No new System Map write action was introduced here.

## 8. Manual and verification

A full “Group cards and add-ons on the map” chapter exists in all eight manual
languages. Obsolete Flutter Setup/Add-ons page instructions in the development
supplement have been replaced. The production GTK manual sections remain because
GTK was deliberately unchanged. Existing translation source values, order and
formatting are preserved; new entries were appended. The new manual sections are
fingerprinted. Earlier `about` / `running-agents` fingerprint drift is not claimed
resolved by this milestone.

- Broader Python suite: **1,324 tests passed**, 44.3 s. Five existing host-only
  modules remain excluded here: `test_add_mcp_test_button`, `test_back_keys`,
  `test_herdr_state`, `test_loopback_stream`, `test_review_fixes`.
- New backend regressions: **9 passed**, covering reversible removal, occupied
  destinations, transaction rollback, bundled/stale folders, owned/external-agent
  guards, immediate switch/Undo, failed-load rollback and sign-in metadata.
- Existing catalog tests: **18 passed**; registry tests: **6 passed**; setup tests:
  **9 passed**. Three catalog mocks were updated to supply the registry’s explicit
  `items` inventory required by the new guard.
- Manual structure tests: **4 passed**; sync-boundary tests: **5 passed**.
- Pinned Pyright: **0 errors**, five pre-existing PyYAML-source warnings in this
  environment. Dart transport checks passed. All language catalogs are complete.
- Flutter analysis: **No issues found**.
- Full `flutter test --no-pub --timeout 60s` was attempted. The sandbox rejects
  the runner’s `127.0.0.1` server socket before test execution. Widget regressions
  cover dummies, graph separation, focus keyboard/camera preservation, explicit
  catalog access, default-size welcome footer, detection/manual selection and
  running-agent controls. Their host execution remains pending; no host pass is
  claimed and no settling assertion was replaced with a timed pump workaround.
- 60-second AI Map backend profile: **1.2% of one CPU core**, 30 calls, one worker.
  The expanded-view desktop/GPU measurement remains a host check. The focus UI
  has no recurring animation or new scan cadence.
- Native Linux preview: **build passed**, at
  `.flutter-previews/preview-k7w0vd26/flutter_app/build/linux/x64/release/bundle/asterism`.
  It has the development application identity and was not installed or launched.
- `git diff --check` passes.

Host follow-up remains required for widget execution, real window/keyboard and
first-use smoke testing, idle CPU with a group expanded, and manual PDF rebuilding.
The existing Chromium/socket sandbox blocker still prevents that PDF build; PDFs
were preserved. On the host, use the existing `docs/manual/build.py --all` workflow
with the installed plugin version. The plan’s per-step host-green checks are not
claimed complete from sandbox results alone.

No GTK UI change, plugin sync, credential-file read, AI request, package install,
commit, push or publication was performed. This is still a development preview,
not completion of the overall Flutter migration.


## Follow-up review A1–A5

The later [review responses](review-claude-2026-10-28-map-addons-responses.md)
supersede the initial external-agent guard and unbounded-backup behavior above.
Only app-owned sessions and installs now block adapter changes. Shared GTK-folder
effects and the 30-day backup cleanup policy are disclosed before confirmation.
The double-tap recognizer was removed, with the original settling tests retained.
