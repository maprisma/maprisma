# Asterism: full Flutter desktop application

User decision, 2026-10-27: start migrating; the final application must be Flutter.
This supersedes the earlier recommendation to retain GTK as the long-term UI.
The one-application identity, settings migration and thin Omarchy launcher remain.
No automatic marketplace publication, push, release or upload is authorized.

## Current checkpoint — 2026-10-28

The Flutter migration is a tested development app, not yet the production GTK
replacement. The baseline was committed on main (`ddae426`, `fb154d2`); finished
milestones and reviews are in `docs/history/`. Work continues on main without
pushing it to the `gtk` remote.

**Decision (Uwe, 2026-10-28):** Flutter replaces the GTK app on Linux too; the GTK app gets fixes only.
Map editor (committed 5cb3069): [plan](history/plan-flutter-map-editor.md) and
[implementation and measurements](history/plan-flutter-map-editor-responses.md):
bounded light tiles and static caching reduce controlled lights-on Xvfb CPU from 134.53%
to 56.30% of one core. Claude’s real-desktop GPU measurement, with Uwe’s OK,
passes the map-editor performance gate: 0.05% idle, 9.57% with lights at zoom .53
and 9.07% at zoom 1.25, matching GTK’s 8–11% reference. Software figures remain
the no-GPU/VM worst case. The pacing Low was later fixed with the 20/30/60 fps setting; the pass
applies to the measured 20 fps implementation.
The [map-lights review responses](history/review-claude-2026-10-28-map-lights-responses.md)
cover live-scan reuse and measured continuous hover/high-zoom costs.

The current parity inventory and local connection-authoring slice are in
[plan-flutter-connections.md](history/plan-flutter-connections.md). Custom MCP definitions
and explicit local skill-folder attachment now use the existing reviewed
configuration/backup/Undo flow. Skill symlink plans can cross the private worker
wire. Online MCP/skill catalogs, web skill installation and tool probes remain
unported; this slice does not claim those flows are complete.

Baseline validation before this slice: 50 Flutter tests and 1,381 Python tests,
clean analysis/typechecking, all eight PDFs rebuilt, native Devel build and
Claude's seven task-card findings verified. Current slice checks/results are
recorded in [plan-flutter-connections-responses.md](history/plan-flutter-connections-responses.md).
Earlier test counts, uncommitted-tree descriptions and sandbox/socket/PDF blockers
in the dated implementation notes below are historical; current checks run here.

## Completion means

Flutter owns the complete interface **and the service**: the shipped app is Flutter/Dart only, with no
Python in the bundle (Uwe, 2026-10-28; `plan-flutter-dart-core.md`). Python stays in the repository as the
reference implementation and test oracle (differential tests) until every route is ported. A Flutter shell around a running GTK
window does **not** satisfy this goal. Keep the current application available until
feature parity, migration and packaging have been validated.

## Working copy

Work on `main` in `/mnt/Data/Projects/asterism` (was `asterism-flutter` until 2026-10-28). The original GTK repository
at `/mnt/Data/Projects/ai-agents-map` (was `asterism`) is separate and must not be overwritten or synced
from this migration. Its local remote is named `gtk`; never push Flutter main
there. The baseline migration, documentation archive and reviewed connection-authoring
slice (`69464c8`) are committed. Further work remains local unless Uwe requests
a commit.

## Architecture

- `flutter_app/`: Material Flutter desktop UI; eight existing languages, real map,
  agent details, per-agent project choices and terminal views.
- `flutter_backend.py`: versioned bounded JSON lines over private stdin/stdout,
  launched as the UI's child. No port, HTTP server, shell execution endpoint or
  executable path supplied by UI data. Reuse existing Python policy and adapters.
- `terminal_sessions.py`: owned Unix PTY sessions, fixed adapter argv, actual cwd,
  input acknowledgements, output backpressure, resize and explicit stop. The Flutter
  xterm widget renders terminal escapes; terminal output stays in memory.
- Existing signed GTK widget add-ons require a new UI contract. Do not assume
  reusing Python makes those widgets compatible. Service-side agent/provider
  extensions and Flutter feature pages need separate, versioned contracts.
- Desktop theme/integration and app identity are separate. Preserve production app
  id `io.github.ubruckhaus.Asterism` and the existing settings directory.

## Migration checklist

1. **Foundation and sessions implemented:** private service protocol, real
   adapters, project history/defaults/pins, both terminal modes and close guards.
   Automated tests pass. Real-desktop terminal keyboard/paste/selection, process
   lifecycle and singleton/multi-window scenarios still require validation.
2. **Maps and task cards implemented:** AI/System Map, discovery/reconnect/moves,
   groups, add-on management, metadata/subagents and review/progress/result cards.
   Map editing/layout and keyboard alternatives are implemented locally for review;
   the real-desktop GPU performance gate has passed. Broader desktop validation
   and the optional pacing Low remain; software-renderer costs are documented.
3. **Complete feature parity:** work through the inventory linked above. Local
   MCP creation/skill-folder attachment are implemented in the current slice.
   Remaining: MCP/skill catalogs and checks, web skill installation, direct API-key
   entry, full settings/security/help/notification views, tuning, durable jobs,
   prerequisite/runtime installer UI and returning completed setup actions to the
   guide. Installer service routes and their Flutter UI are connected (6b-1, 2026-10-29): the
   first-agent guide's mise/Node.js/local-LLM steps and Install under Providers and models. Steps
   started from the guide return to it, refreshed (6b-3).
   Signed agent/provider add-ons work, from the catalog or a file (6b-4); Flutter
   feature/extension add-on contracts remain. Other adapter readers/collaboration views remain.
4. **Product fit and migration validation:** finish keyboard/accessibility,
   recovery, safe live-agent updates, desktop theme behaviour during operations,
   cross-process settings coordination and clean-VM scenarios. New UI remains in
   all eight languages with manual updates; current manuals are rebuilt.
5. **Omarchy integration (Uwe, 2026-10-28):** on Omarchy the Flutter app must feel
   like the plugin does today, without becoming a different app elsewhere. Only when
   `desktop.NAME == "omarchy"`; other desktops keep a normal window.
   - **Popup under the bar icon:** an optional popup mode as a layer-shell surface
     (Flutter's Linux embedder is GTK, so gtk-layer-shell via a pinned, reviewed pub
     package such as `wayland_layer_shell`, or a small own plugin in `linux/`),
     anchored top-right under the bar with the bar's real thickness (the shell's
     `barSizeFor`, see the 4.5.0rc2 bar-window change), Esc/outside click closes,
     keyboard focus only while open, no grab on a bare Super press. Normal-window
     mode stays the default off Omarchy and selectable on it.
   - **Theme:** follow Omarchy's theme live from the existing `app.theme` service
     route (`desktop_omarchy.theme_colors`, `colors.toml`), including theme switches
     while a task card or terminal is open; rounding from `window_rounding()`.
   - **Hyprland:** floating size/position and focus-or-start through the existing
     `desktop_omarchy` helpers (`focus_window`, `own_window`, window rules in
     `window_rules.py`), one instance per user (the toggle's PID file + SIGUSR1
     contract from `ai-agents-map-toggle`), floating terminal for external starts.
   - **Omarchy data:** agent menu entries and Omarchy's usage records, as
     `desktop_omarchy` provides them to the GTK app today.
   - Tests: widget tests with a fake desktop, plus a check in the edge VM; never
     run Omarchy edge code on Uwe's desktop.
6. **Packaging:** bundle Python and dependencies next to Flutter; resolve bundle
   paths instead of ASTERISM_SOURCE. Validate Linux/AUR/AppImage on a clean system.
   Replace the production entrypoint only after parity and delivery are validated.
7. **A new Omarchy plugin "Asterism" as a thin launcher** (Uwe, 2026-10-28; `plan-one-app.md`):
   a new marketplace plugin `ubruckhaus.asterism` with its own repository, not the old
   AI Agents Map plugin (that one only points its users to the new plugin and gets
   fixes until then). It is a small QML bar widget + toggle that focuses or starts the installed
   Asterism (popup mode from step 5) and offers its installation when missing (AUR
   via yay/paru, else the AppImage with SHA-256 check, shown in a visible terminal).
   It ships no Flutter binary or Python bundle: the marketplace reviews source only.
   Existing settings move over once with a backup (`config_migration.py`).
8. **Finish:** final independent review at full parity, then release decisions by
   Uwe. No automatic installation, plugin sync, push, upload or publication.

## Development commands

From this repository, use the installed SDK directly when the Arch FUSE wrapper
is unsuitable:

```bash
PATH=/home/uwe/Work/flutter-sdk/bin:$PATH ASTERISM_PUB_OFFLINE=1 tools/flutter-dev check
PATH=/home/uwe/Work/flutter-sdk/bin:$PATH ASTERISM_PUB_OFFLINE=1 tools/flutter-dev build
python3 -m unittest discover -s tests -q
UV_OFFLINE=1 tools/typecheck.sh
```

Checks and widget tests run here; a separate host terminal is no longer required.
The builder creates a separate `.flutter-previews/preview-…` bundle with Devel
identity and prints its executable path. It neither installs nor launches it.
Development builds still use this checkout's Python service through an explicit
source define, so a successful build is not a self-contained distribution.
`tools/flutter-dev run` opens a window explicitly and is not an automated test.

## Remaining UI coverage

| Area | Flutter state | Existing source to preserve |
|---|---|---|
| Agent catalog/search/details | Catalog/details and usage built; reviewed recipe install/update/remove, registered terminal sign-in, fixed-question testing and direct API-key entry (6b-2) added | `agents.py`, `agent_details.py`, `details_pages.py` |
| Projects/start | Submenu, history/pins/trash and both terminal modes implemented; host interaction checks pending | `agent_projects.py`, `agent_start_dialog.py`, `terminal_pane.py` |
| Map | Expandable category groups, UI-only empty placeholders, focus controls, retained views, graph, selection, layer filters and live activity/subagent badges built; layout/editing and host interaction checks pending | `graph.py`, `map_view.py`, map helpers in `ai_popup.py` |
| Settings/theme | Language, start folder, appearance, map layers and subagent history controls built; Omarchy theme refreshes while idle; remaining settings pending | `settings_schema.py`, `settings_pages.py`, `desktop*.py` |
| Setup and signed add-ons | Welcome in Agents map focus with fixed Switch on/Later, batch Undo, Look/Skip, immediate add-on toggles, signed catalog, details, user-add-on removal/Undo and provider sign-in menus built; startup migration and signed agent/provider enable/disable built; signed catalog/install/update built; file import and feature/extension UI contracts pending | `setup_page.py`, `addons.py`, `addons_page.py`, `addon_store.py` |
| Providers and models | Start/stop, known-model load/unload, GGUF import, HF search/file selection/download and named pulls built; provider-to-agent configuration/model switching and removal previews built; tuning and full catalog details pending | `models_page.py`, `models_ctl.py`, `provider_*.py`, `llm_engine.py` |
| MCP and skills | Discovered-item browsing and connect/disconnect with structured preview, backup and Undo built; custom stdio/HTTP/SSE definitions and selected local skill-folder attachment now built; online catalogs, tool tests/checks, web skill installation and richer details pending | `mcp_pages.py`, `skills_page.py`, `mcp_ctl.py`, `skills_ctl.py` |
| Usage/security/health | System Map health, confirmed Smart Check/fixes and AI-side usage categories built; broader security views and host interaction checks pending | `agent_status.py`, `agent_security.py`, `smart_check_page.py`, `traffic_page.py` |
| Subagents and collaboration | Five reader formats and Flutter activity/details built; remaining adapter readers and collaboration views pending | `subagents.py`, `subagents_page.py`, separate reader checkout |
| Jobs/helper/install/configure | Worker jobs and initial first-agent checklist built; supported agent recipes run in an external terminal, sign-in/test in owned terminals; prerequisite/runtime installer pages, starter-model guidance, API keys, helper and durable jobs pending | `jobs.py`, `ai_helper.py`, `first_agent_page.py`, `install_dialog.py`, `configure_menu.py` |
| Help, notifications and packaging | Map help/AI guidance and translated manuals built; complete help/notification UI and bundled delivery pending | `info_page.py`, manual sources, `packaging/`, singleton/window helpers |

Continue this checklist until all required actions are represented in Flutter.
Do not replace the production entrypoint, publish, or describe this initial build
as the completed migration. The requested final Claude review remains pending.

## Provider/model and connection controls (continued implementation)

- `flutter_providers.py` validates named operations and reuses runtime/model
  adapters. Commands, URLs, download destinations and split-file paths cannot be
  supplied by the Flutter client. File metadata is resolved again and its size
  compared with the user's selection before a download starts.
- `flutter_tasks.py` / `flutter_worker.py` run long operations in owned subprocesses
  with bounded JSON progress/results. The main service stays single-threaded and
  continues servicing PTYs. Late cancellation preserves completed results, and
  shutdown reaps owned workers and terminals even if termination signals repeat.
  Persistent retry/resume and a jobs page remain separate work.
- `flutter_connections.py` holds the raw MCP/skill plans in Python. Flutter gets
  action metadata, file names and changed-line counts, never configuration text
  or MCP environment/header values. Apply/Undo use opaque single-use handles;
  existing core backups and stale-file checks remain authoritative. Pure file and
  skill-link changes are supported. Provider plans now use a private worker
  handoff for file commits and model API contexts; arbitrary command plans remain
  rejected. Undo restores files but cannot undo provider API contexts.
- The shared language helper now uses `ai_core`'s reader/writer, fixing its former
  64 KiB truncation path that could discard a large project history on a language
  change. Regression tests also cover explicitly configured settings paths.
- New Flutter screens and widget test sources compile/analyze cleanly. The Linux
  preview builds, 1,171 available Python tests pass, and pyright has zero errors
  (the existing five PyYAML warnings remain). Flutter widget execution, real
  downloads/runtime actions, GUI/VM scenarios and final Claude review are pending.
- Latest isolated build:
  `/mnt/Data/Projects/asterism-flutter/.flutter-previews/preview-fv2djdob/flutter_app/build/linux/x64/release/bundle/asterism`.
  Builds do not replace an existing preview bundle or the live production app.


## Provider connections, removal and live activity (continued implementation)

- Connections now includes supported provider-to-agent configuration and model
  switching. Configuration and API context plans cross an inherited private,
  unlinked file descriptor, never frontend JSON or process arguments. Apply runs
  off the main PTY service; public results contain only opaque Undo handles and
  context-failure counts. Running commits cannot be cancelled mid-write.
- Model removal has a single-use, expiring preview. Registered provider/model
  identity, exact file identities, model root and shared references are checked
  again in the worker. Local files/links use the existing Trash operation;
  provider API deletion is explicitly permanent. Tests use temporary fixtures and
  mocks; no installed model was removed.
- The map refreshes visible activity every two seconds, combines external and
  owned session PIDs without duplicate counting, and opens recent delegated
  sessions from badges or the agent detail page. Only kind/folder/age/activity
  metadata reaches Flutter; task descriptions and transcript bodies are omitted.
- Built-in reader declarations now cover Claude, OpenCode, Codex, Copilot and
  Goose. New bounded readers require explicit delegated-session metadata, skip
  symlinks and cache unchanged file metadata. Ordinary Codex conversation forks
  are excluded. Copilot lifecycle tails and duplicate Codex rollout copies have
  fixtures. Goose uses recent activity when completion markers are unavailable.
  Activity indicators are metadata estimates, not proof of a live child process.
  Unsupported adapters explicitly report unavailable rather than zero.
- The available Python suite passes 1,171 tests with the same five restricted
  modules excluded. Flutter analysis and formatting, Dart transport, all eight
  translation assets and translated manual-source checks pass. Widget test
  sources now also cover model switching, removal confirmation and independent
  subagent badge activation; their runtime execution still needs the host.

## Interim Claude review response (2026-10-27)

The interim review is addressed item by item in
`docs/history/review-claude-2026-10-27-responses.md`. Service resolution, sync boundaries,
non-interruptible commit shutdown, recoverable framing, terminal input/cleanup,
map workers, confirmation/close behavior and bounded client buffers are corrected.
Project history now retains 50 folders per agent. Flutter requests native singleton
behavior. The final migration review is still separate.

The sandbox-compatible aggregate passed 1,181 tests with the five display/socket
modules excluded; an additional resolved-home/config-link migration regression
passes separately. Python typechecking has zero errors and five existing warnings.
Dart transport checks, translated manual sources and Flutter analysis/formatting
pass. Widget execution is still denied a loopback socket. Production manual sources
omit preview-only paragraphs; PDF regeneration was attempted but Chromium received
SIGTRAP here, so the host PDF build remains outstanding. Nothing was installed,
committed, synced to the live plugin or published.
The review-fix native development build also succeeds:
`.flutter-previews/preview-zag2l7ax/flutter_app/build/linux/x64/release/bundle/asterism`.
It was not launched against live settings.


## Welcome, subagent settings and live appearance (2026-10-27)

Work now continues in `/mnt/Data/Projects/asterism-flutter`. The original
`/mnt/Data/Projects/asterism` remains untouched. Existing development binaries
built before the move retain their old source define; use the new preview below.

- A fresh Flutter installation opens a native welcome page, including when no
  add-ons are installed. Detection runs in a worker, with retry after failure.
  Detected signed agent/provider adapters are recommended; choices made while
  detection runs remain authoritative. Details exposes the description and
  read/send disclosures before switching anything on.
- Switch on validates the entire selection, reloads only supported verified
  adapters, and records setup completion only after all selected adapters load.
  A load/save failure restores the previous runtime selection. Feature/extension
  choices and missing add-ons remain saved. Later changes only setup completion;
  neither path installs programs. Setup in the header reopens the flow.
- Settings exposes the existing finished-subagent age/count controls with the
  same schema validation as GTK. The activity reader uses these saved values.
- A lightweight theme call updates Flutter's appearance every two seconds while
  idle, independently of whether the map is visible; it does not rebuild the
  agent inventory. Broader settings parity and active-operation theme watching
  are still pending.
- All UI strings are present in the eight translation assets. The development
  supplement `docs/manual/flutter-preview.html` describes this milestone in eight
  languages and stays outside the production manual/PDF build.

Validation: **1,193 Python tests pass**, with the same five display/socket-only
modules excluded. The focused Flutter-service suite passes 80 tests. Python
checking has zero errors and the same five PyYAML-source warnings; Dart transport,
manual-source checks, Flutter formatting and Flutter analysis pass. Two new widget
tests cover recommendations/manual exclusions and applying while detection runs;
widget execution remains blocked at loading by the denied loopback socket.

New isolated native Linux development build (built, not launched):
`.flutter-previews/preview-8zq434av/flutter_app/build/linux/x64/release/bundle/asterism`.
It resolves its service from the new project path. Nothing was installed,
committed, synced to the live plugin or published. Next parity work is the signed
add-on catalog/install/update flow and the first-agent guide, followed by the
remaining UI coverage table. Full host GUI validation, PDF regeneration,
distribution packaging and the final Claude review remain required.


## Signed add-on catalog and installation (2026-10-27)

- Add-ons now offers Available/Get add-on and Refresh. Browsing uses the existing
  signed catalog, version compatibility and cache policy in a worker. The
  Look for add-ons online switch is exposed; disabling it permits reading the
  signed cache but refuses downloads in both service and worker.
- Catalog cards and installation/update confirmation show the reviewed version,
  privacy level, declared capabilities and read/send disclosures. Unsupported GTK
  feature add-ons are marked unavailable and have no actionable install preview.
  Existing installed add-ons expose the same privacy details.
- The service holds single-use, ten-minute opaque preview handles. The frontend
  receives neither archive addresses/hashes nor install destinations. The worker
  resolves the signed entry again and compares the entire reviewed record, then
  rechecks the installed version before using the existing archive hash/signature
  verifier and safe unpack/replace implementation. A changed entry, disclosure or
  installed version requires a new preview. Failed queue submission keeps the
  preview available for retry; a failed installation refreshes the UI catalog.
- Private installation records cross an inherited unlinked FD, not argv or
  frontend JSON. Add-on installs join the non-cancellable commit operations.
  Shutdown drains/waits, then lets an unusually slow install finish detached.
  A private per-user flock serializes detached installs with a restarted UI;
  version checking occurs under the lock. No add-on code executes just to browse
  or download the catalog. Supported enabled adapters reload only after a
  completed installation. Saved enable/disable choices are preserved; a newly
  introduced id stays off by default.
- Owned running agent sessions block installation; new owned sessions and setup/
  enable changes are blocked while installation is running. External agents are
  not stopped. No agent program installer or arbitrary command endpoint is added.
- New UI text is translated in all eight languages. The eight-language development
  supplement `docs/manual/flutter-preview.html` describes the flow, outside the
  production manual/PDF build.

The first-agent guide, local archive import, add-on removal and Flutter feature/
extension contracts remain unfinished. The core catalog installer retains its
existing archive replacement/trash behavior; this change does not claim a new
persistent add-on rollback system. Host scenarios still needed: download failure,
confirmation/cancel, online preference, enabled adapter upgrade, and close/restart
during download/commit. Nothing was downloaded from the live catalog or installed
while implementing this feature; tests use temporary fixtures and mocks.

Final validation: **1,211 Python tests pass**, excluding the same five modules
requiring a display or sockets. Eighteen new catalog tests include a real
concurrent-process stale-update regression; archive/signature fixtures and commit
shutdown tests pass. Typechecking reports zero errors and the five existing
PyYAML-source warnings. Flutter analysis and formatting, Dart transport, manual
source checks and sync-selection checks pass. Three new widget tests cover
eligibility/disabled actions and install/update confirmation; widget execution is
still blocked before loading by sandbox-denied loopback sockets.

An isolated Linux development build succeeds at
`.flutter-previews/preview-oenn752o/flutter_app/build/linux/x64/release/bundle/asterism`.
It was not launched against live settings. No commit, production installation,
live plugin sync, push or release was performed. Next parity work is the
first-agent guide and remaining agent install/sign-in/configure actions.


## Claude recheck fixes and configurable map scans (2026-10-27)

`docs/history/review-claude-2026-10-27-recheck-responses.md` records N1–N7 individually.
The map scanner is persistent, isolated from work slots, and defaults to full
scans no more often than every six seconds while visible. Settings now allows
manual-only or 6/15/30/60/120/300 seconds; automatic scans pause while unfocused
by default. Automatic targets can be selected independently: activity/subagents,
agent details, and combined model/MCP/skill inventory. Other groups retain their
cached state. Startup/first map load and explicit Refresh always refresh all
three groups; manual-only mode still polls an explicitly requested scan to
completion. Settings changes while the map is hidden do not trigger a map scan.
Terminal I/O and explicit jobs are not throttled by these controls.

On this fast CPU, 60-second profiling of the same 56-node / 74-edge map dropped
from Claude's 12.6% of one core to **1.2%** at default six-second full scans, and
**0.4%** with thirty-second activity-only scans. Each run used one worker instead
of 30. These measure the service/scanner, not Flutter rendering or slower hardware.
For weaker CPUs use longer intervals, activity-only targets or manual-only mode.
The worker retains its import, signature/registry and metadata-reader caches.

Preview build/run now assigns `io.github.ubruckhaus.Asterism.Devel` only in the
staged runner. Production packaging keeps `io.github.ubruckhaus.Asterism`. The
preview still uses the existing settings location: no live launch was performed.
Descendant cleanup uses recorded identities and pidfds; permanent task-status
errors close as failures; migration notices are translated and shown once in GTK;
failed migration backups roll back. Translation source ordering/format is restored.
The eight-language development manual describes the new scan controls.

Validation: **1,221 Python tests passed**, with the five display/socket-only
modules excluded; zero type errors, five existing warnings. Flutter analysis,
formatting, Dart transport, manual-source and sync checks pass. Native Devel build:
`.flutter-previews/preview-r_i_721m/flutter_app/build/linux/x64/release/bundle/asterism`.
The compiled runner contains the Devel id. New widget runtime checks remain blocked
by denied loopback sockets. Manual PDF regeneration was retried with an isolated
browser profile; Chromium still receives SIGTRAP, so the existing PDFs remain and
must be rebuilt on the host. Desktop smoke testing and final review remain open.
No commit, installation, live plugin sync or publication was performed.

## Second Claude recheck fixes (2026-10-27)

`docs/history/review-claude-2026-10-27-recheck-2-responses.md` answers R1–R4.
The task-error widget fixture now performs file setup synchronously, and the check
command sets a 60-second per-test timeout. Manual Refresh arriving during a partial
automatic scan queues a full scan and remains pending until it finishes, including
in manual-only mode. Automatic scan invalidation now compares relevant normalized
settings and owned-session identities; unrelated history/setup writes do not
bypass the chosen interval. Descendant cleanup is unchanged, per R4.

Validation: 1,223 Python tests pass with the same five host-only modules excluded;
zero Python type errors and five existing warnings; clean Flutter analysis and
formatting; Dart transport passes. The widget run still cannot load here because
loopback sockets are denied. Host widget checks, PDF regeneration, desktop smoke
testing and the final migration review remain required. No production launch,
installation, commit or publication was performed.


## First-agent checklist and reviewed agent actions (2026-10-27)

- Setup now offers Set up your first agent; a rocket button in the header reopens
  the checklist. Online/local routes come from the validated existing catalog,
  with saved route selection. Checklist construction runs only on an explicit
  request, in its own scan worker, not in the PTY service or an idle timer.
- Credential readiness uses the existing existence/environment-presence helper;
  credential files are never opened. Missing signed adapters link to Add-ons.
  Local runtime/model steps link to Providers and models, and configuration links
  to Connections with its existing preview/backup/Undo controls. Existing local
  connection/activity state is checked, rather than declaring configuration done
  merely because a route was chosen.
- Agent details offers only supported recipe install/update/remove, registered
  sign-in and fixed-question actions. A preview shows the exact recipe, notes,
  sign-in method and retained data for removal; commands can be copied. A new
  five-minute single-use handle is re-resolved against the adapter/installation
  state before any execution. No frontend command, argv, URL or destination is
  accepted. Failed launches leave the handle available for retry.
- Install/update/removal reuse `install_recipes` and its visible external terminal
  path. Passwords remain in that terminal. Closing Asterism does not close that
  external installer; use Refresh afterwards. Updating/removing an owned running
  agent is refused. These external commands are not new durable/resumable jobs,
  and external agent processes are not stopped or claimed as owned.
- Registered sign-in commands and the fixed ask command run as owned PTYs with
  cleaned agent-session variables. The question cannot be changed by frontend
  data and uses a private temporary directory instead of a user project. Only
  non-empty output with a successful exit marks the agent verified; failed/stopped
  tests do not. The output remains in terminal memory, not settings. Verification
  errors preserve final output and show the existing failure indicator. The user
  can Stop a sign-in/test session; it is an interactive terminal, not a timed
  background verification job. Temporary directories are cleaned on completion,
  explicit stop and shutdown.
- New UI text is translated in all eight languages, preserving source file order
  and format. The eight-language development manual documents this milestone.

Remaining guide parity is explicit: prerequisite and runtime installer pages,
GPU/starter-model/context recommendations and automatic loading, direct API-key
entry, and returning directly to the guide from a completed operation. The guide
currently links existing model/provider/connection views rather than silently
performing those setup actions. Manual/internal-installer recipes stay display-
only in the new action interface. The full migration is still in progress.

Validation: **1,239 Python tests pass**, excluding the same five host-only
(display/socket) modules. The focused Flutter-service suite passes 122 tests;
16 new action/guide tests include a real Python PTY fixture, with no actual agent
or package installation. Pyright reports zero errors and the same five existing
PyYAML-source warnings. Flutter analysis/formatting, Dart transport, translated
manual-source checks and sync-selection checks pass. Existing source translation
values were compared with HEAD and remain unchanged.

Two new widget tests cover route/action wiring and command/removal confirmation.
Widget execution is still blocked at loading by denied loopback sockets; the
previous all-host result does not establish runtime results for these new tests.
The new isolated native Devel build succeeds:
`.flutter-previews/preview-peuj1zki/flutter_app/build/linux/x64/release/bundle/asterism`.
It was not launched against live settings. No installed program or add-on was
changed; nothing was committed, installed, synced to the live plugin or published.
Host desktop testing, PDF regeneration, full feature parity and final review
remain outstanding.

## Reuse AI installations on a separate mount (2026-10-27)

Uwe approved the scenario in `docs/history/idea-detect-existing-ai-installs.md`. The
Flutter Providers and models page and first-agent guide now offer **Find existing
AI**. Discovery is explicit, not a startup or automatic map scan.

- `existing_ai.py` parses local mountinfo, scans one selected mount/folder in a
  worker and caps depth (5), entries (12,000), elapsed time (5 seconds), results
  (128) and response size. It skips hidden/other-user folders, network/FUSE and
  system mounts, mounted subtrees, and links leaving the disk. Limits are visible;
  selecting a smaller folder is the recovery path. Limits cannot interrupt a
  kernel filesystem call that is itself blocked.
- Provider modules declare discovery and reconnect rules: native ELF llama.cpp
  and Ollama binaries, nearby portable ROCm trees and Ollama model stores. GGUF
  folder discovery is generic. No old home configuration or credentials are read.
- Reuse model folder saves `model_folders` without moving/downloading files; these
  paths also appear on the Flutter Providers page. Runtime reconnect requires a
  discovered model-folder selection and previews the exact generated wrapper,
  environment file and systemd user service with `RequiresMountsFor`.
- All connecting files must be absent and their parents free of symbolic links.
  Existing settings are preserved and backed up. Opaque ten-minute handles and
  inherited private plan FDs keep paths/commands out of apply requests. The worker
  rechecks mount identity, file identities, settings and generated content under
  the app installation lock. Reconnect commits finish when the UI closes. The
  existing connection backup/Undo mechanism removes generated files and restores
  folder settings while preserving subsequent edits.
- Discovery never executes binaries. A separately confirmed **Check program**
  invokes only the selected program's `--version`, for at most five seconds, with
  discarded output, a temporary home, clean environment, and child-group cleanup
  on timeout/cancellation. This is execution as the user, not an OS security
  sandbox, and does not guarantee GPU or new-distro ABI compatibility.
- No services are enabled/started automatically. Enable the signed provider add-on
  and use the separate Start action. The existing files on the data disk remain
  external installations; Asterism does not claim ownership for updates/removal.
  `/etc/fstab` is not edited: the UI reminds the user to preserve the mount path.
  Old router presets/tuning are not copied across distro homes. Native reconnect
  currently excludes paths containing backslashes/double quotes; scripts and
  installations owned by another UID are not adopted.

The eight-language development manual and Flutter strings document the flow.
Map drag-to-adopt nodes, other providers' detection rules, automatic startup hints
and copying/rebasing old distro-specific presets remain optional follow-ups.

## PC overview, separate-mount guidance and AI simplification help (2026-10-27)

Uwe expanded the separate-mount scenario: first use should explain existing AI
components, Help and Smart Check should suggest simpler shared storage, and a
second map should show the PC's technical configuration.

- Welcome now includes separate-mount and simplification guidance, with buttons
  for discovery and the new PC map. The header opens PC overview, Help and Smart
  Check. All three guidance surfaces explain checking mounts before reinstalling
  or downloading models again. Existing startup adapter detection is retained;
  broad disk discovery remains explicit, independent of automatic AI-map scans.
- `flutter_pc.py` builds the second map in a worker on request: OS/architecture,
  CPU threads, RAM, GPU, home and local mounted disks, free/total storage, known
  agent/runtime programs, configuration directories and model folders. Built-in
  detection facts also provide an overview before the corresponding adapters
  are enabled. Only metadata is returned. Credential files are never opened; provider
  detection reads its existing configuration to locate models, but raw
  configuration contents are not exposed. The latest explicit disk discoveries can appear
  after refreshing it. Node/edge/response caps bound the overview.
- The existing Flutter map renderer accepts alternate column headings and node
  selection, preserving the normal agent-map behavior. The PC map supports pan,
  zoom and selecting full paths and hardware/storage details.
- Smart Check currently provides local observations about unavailable model
  folders, alias paths and multiple model roots. These are review hints, not
  content hashes or proof of duplicate models. Help explains sharing storage,
  reducing redundant services, checking references, and keeping backups.
- Where an installed, enabled adapter supports guarded tasks, AI help offers a
  helper selector and **Ask AI for a plan**. An expiring single-use preview shows
  the exact fixed-topic prompt and PC metadata (including folder paths) before
  a user-confirmed owned PTY session. The existing `ai_helper.task_argv` approval
  guard is re-resolved before launch. No frontend prompt, shell command, URL or
  argv is accepted. The prompt requests read-only explanation first, approval
  before every change, no credential-file reads and no automatic cleanup. No
  AI service is contacted while opening Welcome, Help, Smart Check or the map.

This focused Flutter Smart Check view does not yet include the legacy page's
complete online update analysis, task/token history or every repair action.
Automatic deduplication, file moves and service consolidation are not introduced;
those need a concrete preview and the existing safe file-management workflows.
Eight-language strings and development-manual paragraphs cover both milestones.

Validation for the separate-mount and PC-overview milestones: **1,278 Python
unit tests pass**, excluding the same five host-only GTK/socket modules. This
includes 29 new discovery/reconnect tests and 10 PC-map/AI-preview tests, using
fake mounts, temporary homes and mocked agent launches. No actual AI query,
installer or live reconnect was run. Read-only checks on this PC found the
standalone llama.cpp build, Ollama, its model store and linked GGUF folders;
Ollama's embedded llama-server is excluded as a standalone installation. A
read-only PC overview returned the expected hardware/disk/program/folder kinds.

Pyright reports zero errors and five pre-existing PyYAML-source warnings. Flutter
analysis, Dart transport, translation preservation/uniqueness, manual and plugin
sync-selection checks pass. Four new widget tests cover explicit discovery,
preview/apply/Undo, confirmed version checking, Welcome entry points and map/help
navigation; this sandbox cannot bind the local Flutter test socket, so host
execution and visual review remain pending. Manual PDFs retain the previously
recorded Chromium rebuild blocker; these additions are in the development
manual supplement, not a published release.

Latest isolated build (not launched or installed):
`.flutter-previews/preview-_j62rkac/flutter_app/build/linux/x64/release/bundle/asterism`.

## Claude's separate-mount review responses (2026-10-28)

`docs/history/review-claude-2026-10-28-responses.md` answers E1–E6. Welcome now has a
fixed bottom action row. Discovery preserves and validates `current` launch
aliases (including indirect link components and targets) instead of pinning
build versions. Generated services identify their provider and use `%h`; the
new llama.cpp model preset uses `$HOME`, starts with `gpu-layers = all`, and is
covered by absence checks and Undo.

The preview explains fresh tuning and runtime-default GPU selection. Automatic
GPU device pinning remains deferred: sysfs/driver facts do not establish that
particular binary's ROCm/CUDA device IDs, and discovery must not silently execute
it to obtain those IDs. The review response records this limitation explicitly.

Discovery separately reports depth/entry/time/result/response limits, skipped
foreign-owned folders and candidate paths, and cross-filesystem/subvolume
exclusions. GGUF results warn about speech/vision model types. AI consent now
explicitly names an online model's service as a data recipient. All new text and
manual notes cover eight languages. The idea document records the approved
entry points, units-plus-wrapper scope and Flutter target.

Review-fix validation: **1,285 Python tests pass**, excluding the same five
host-only GTK/socket modules, including 36 discovery tests. Flutter analysis is
clean; Python type checking has zero errors and five existing PyYAML-source
warnings. Dart transport, wrapper syntax, manual/sync-selection tests,
translation preservation and diff checks pass. Widget execution and revised-unit
verification remain pending on the host because this sandbox denies their
sockets. The latest built preview is
`.flutter-previews/preview-9c7exvqy/flutter_app/build/linux/x64/release/bundle/asterism`;
its backend uses the current repository source. No live install or configuration
was changed.


## Permanent System Map (2026-10-28)

User-approved implementation plan: [plan-system-map.md](history/plan-system-map.md).
Implementation details, replaced-action inventory, measurements and host checks:
[plan-system-map-responses.md](history/plan-system-map-responses.md).

The Flutter preview now has AI Map / System Map pages with separate retained views,
private cached topology, cheap metadata refresh, explicit bounded disk search,
read-only supporting-tool detection, discovered-install actions and guarded AI
analysis. GGUF folder moves reuse the existing checked-copy and Undo primitives;
custom runtime wrappers are refused when their configuration cannot safely be
rewritten. Reconnect does not start or enable services. The AI Map scanner remains
independent of System Map scans. This milestone does not complete the overall UI
migration or replace the production entrypoint.


### System Map review corrections and storage decision (2026-10-28)

See [Claude’s review](history/review-claude-2026-10-28-system-map.md) and
[the responses](history/review-claude-2026-10-28-system-map-responses.md) for S1–S6.
Confirmation dialogs disable controls without animating an idle progress bar.
Missing disks can be forgotten from saved topology only; settings and files stay.
Program sizes resolve known wrapper targets, and discoveries display `current`
launch paths separately from the resolved build. All AI previews share one limit.

Storage is deliberately profile-aware: with an explicit `settings_path`, the map
is `<settings-parent>/system-map.json`; without one it is
`identity.cache_dir()/system-map.json` (honoring `XDG_CACHE_HOME`). New move-Undo
journals are always `<settings-parent>/model-moves/`, using the identity’s normal
settings folder when no explicit path was given. Undo also checks the old default
cache location for existing journals; those journals must be retained until their
moves are undone. No existing data is moved by this change. The map is rebuildable;
Undo journals and their configuration backups are durable recovery data.


## Group cards and map add-on management (2026-10-28)

Active approved plan: [plan-map-addons.md](history/plan-map-addons.md).
Action inventory and results: [plan-map-addons-responses.md](history/plan-map-addons-responses.md).

1. Inventory completed before removing UI pages; gaps in new MCP/skill creation
   remain explicit.
2. UI-only `MapGroup` and dashed empty group cards added to all AI Map categories.
   They never modify graph facts, counts, edges, caches or AI summaries.
3. Focus expansion, keyboard/background collapse and a finite 200 ms AI Map
   transition added. The same map controller/selection survives focus changes.
4. Immediate switches and one-action Undo, signed-catalog update menus, provider
   sign-in, permissions and backed-up user-add-on removal added. Backend guards
   check app-owned sessions and active installations; failed enables roll back.
5. First use opens Agents focus, with detected agents marked and fixed Switch
   on/Later controls. Other enabled adapter kinds are preserved. Welcome Look/Skip
   and System Map remain available. Only the first startup auto-expands.
6. Flutter Setup and Add-ons pages and navigation flags removed. Existing service
   routes and normal agent/model/connection actions remain.
7. System Map uses the shared group-card/focus controls for all five columns.
8. Full manual chapter and updated preview supplement provided in all eight
   languages. Host widget, desktop and PDF checks remain pending; see responses.

The 60-second backend profile remains 1.2% of one CPU core. Expanded-view desktop
CPU must still be measured on the host; no idle animation is introduced beyond
actual task progress. This remains a development preview, with no production
entrypoint replacement, commit, plugin sync or publication.


### Map add-on review corrections A1–A5 (2026-10-28)

See [review responses](history/review-claude-2026-10-28-map-addons-responses.md).
External agent processes no longer block add-on changes in either the frontend
or service; owned sessions and installs remain guarded. Group activation uses one
tap handler, avoiding the double-tap recognizer’s delay. The shared GTK add-on
folder is deliberately retained and disclosed in removal/install/update reviews.
After a successful removal, bounded retention cleanup may delete user-owned UUID
backups older than 30 days; active Undo backups, links and unrelated folders are
preserved. The terminal regression now handles `/proc` disappearance races.
Welcome’s Agents button retains first-use mode and its fixed Switch on/Later row.


## Task cards (2026-10-28)

Implementation of [plan-task-cards.md](history/plan-task-cards.md): task reviews, polling and
results now use the map area, with a read-only focused subgraph for wide half cards.
Model browsing, catalog and guide remain full cards. The main AI map is not built
behind tasks; its external transform/focus state is preserved. See the
[implementation response](history/plan-task-cards-responses.md) for checks and limitations.


### Task-card review fixes (2026-10-28)

All findings in [Claude's task-card review](history/review-claude-2026-10-28-task-cards.md)
are addressed in the [review responses](history/review-claude-2026-10-28-task-cards-responses.md):
one conditional completion scan, single hosted headers, retained view state,
explicit full-width provider overview, idle live updates, compact task maps,
single review counting, post-install catalog refresh and first-result Undo.


## Local connection authoring and parity inventory (2026-10-28)

[Plan and current inventory](history/plan-flutter-connections.md) ·
[Implementation and checks](history/plan-flutter-connections-responses.md).

Connections now offers custom stdio/HTTP/SSE definitions and explicit local
skill-folder attachment with selected agents, structured preview, private worker
commit, backup and Undo. Version 2 of the private wire supports skill link plans;
commands/file installation/retire plans remain refused. The shared half-card
policy now uses measured map-area width for both rendering and scan decisions.
The completed slice passes 55 Flutter tests and 1,395 Python tests with clean
analysis/typechecking; all eight manual PDFs rebuilt. Online catalogs, skill
fetch/install and tool probes remain separate work.


### Connections review checkpoint (2026-10-28)

Claude reviewed and committed the connections slice as `69464c8`; no Medium or
higher finding remains. Analysis is clean and 55 Flutter tests pass. Its plan and
responses are archived in `docs/history/`. Two low argument-entry leftovers are
noted for the next related edit: representing an intentionally empty argument and
normalizing/refusing carriage returns from pasted CRLF. No push was performed.

### Appearance and light-rate settings (2026-10-28)

Settings now persists System/Light/Dark choices with small previews, plus a map-light
frame-rate choice of 20 (default), 30 or 60. See the [plan](history/plan-flutter-appearance.md)
and [implementation response](history/plan-flutter-appearance-responses.md). Uwe waived
further measurement; Claude's accepted GPU gate remains based on the earlier
19–21 fps build. No desktop launch, commit, push or sync was performed.

### Dart-core migration — phase 1 (2026-10-28)

The [Dart-core foundation response](plan-flutter-dart-core-responses.md) records
isolate transport, the Devel-only router, POSIX policies, differential tests and
ported settings/identity/theme/desktop/i18n routes. All other routes still use the
Python reference in Devel; production builds remain blocked. Phase 1 stops for
review before read-only scans or later phases begin.
