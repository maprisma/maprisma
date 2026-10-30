# Maprisma Flutter frontend — migration in progress

The final Maprisma application will use Flutter. This development frontend is the
development implementation of that migration; it is not yet a replacement for every GTK feature.
See [the migration plan](../docs/plan-flutter.md) for completion criteria and gaps.

Implemented source: responsive agent list/details, existing graph data with pan
and zoom, per-agent recent projects/pins/history-only deletion, project selection,
embedded PTY terminals, separate-terminal startup and close confirmation for
owned agents. Settings support language, global project folder, appearance and
map layers. Agent details include existing model/provider/plan/limit/today-usage
metadata. Eight-language UI assets reuse the application's translations.
Start uses a grouped submenu with searchable project history. Service startup
reuses the existing one-time settings migration and verifies signed agent/provider
add-ons; the map focus groups can enable/disable them, with a reviewed signed catalog and user-add-on removal/Undo. GTK-specific feature and
extension add-ons remain listed but unavailable in this frontend, with saved
enabled choices preserved.

Provider/model controls now include supported runtime start/stop, model load and
unload, GGUF import, Hugging Face search/file selection/download, and named pulls
where supported. Long operations run in isolated workers with progress and
cancellation while the service continues handling terminal traffic. Model removal
previews exact files/shared references, then revalidates in a worker: local files
go to Trash; provider API deletion is permanent. Configuration commits and removal
cannot be cancelled mid-write.

The MCP/skills page browses discovered items and connects/disconnects supported
agents through a structured preview, private backup and Undo. Configuration
values stay in Python. Changed files are protected by the existing stale-file
checks; Undo skips later edits. Custom stdio/HTTP/SSE definitions and explicitly chosen local skill-set folders
now use the same preview, backup and Undo flow. Definitions are saved as data;
Maprisma never executes a new server command while adding it. Agents may start
it when reading their configuration. Local skill files remain in place and are
linked or referenced by adapter settings. Online catalogs, connection tests and
web skill installation remain migration work. Provider connections/model switching now
use the same preview and backup flow, with private worker-side API contexts.
Undo restores configuration files only; it cannot undo API context changes.

The map refreshes external and owned session activity and opens delegated-session
metadata from badges or agent details. Claude, OpenCode, Codex, Copilot and Goose
are supported; other agents explicitly report tracking unavailable. Metadata
activity estimates do not establish that individual child processes are alive.

The Linux development build succeeds and the analyzer reports no issues. The
initial executable is `build/linux/x64/release/bundle/maprisma`. Subsequent
`tools/flutter-dev build` calls create an isolated `.flutter-previews/` bundle and
print its absolute executable path, allowing an existing preview to stay open.
Keep each entire bundle directory together. The complete Flutter checks run here;
the current checkpoint is 55 passing Flutter tests and 1,395 passing Python tests. Do not infer complete feature parity from this initial build.

From the repository root:

```bash
tools/flutter-dev prepare
tools/flutter-dev check
tools/flutter-dev build
```

`tools/flutter-dev run` explicitly opens the development window. Do not run it
against the live desktop from an automated test. The original GTK entrypoint and
installed Omarchy plugin are unchanged. The development UI shares Maprisma's
settings; avoid changing settings in both interfaces at the same time until
cross-process coordination is implemented.

On this machine the Arch Flutter wrapper needs FUSE, unavailable in the Codex
sandbox. A writable copy of the installed SDK is available at
`/home/uwe/Work/flutter-sdk`; prefix commands with
`PATH=/home/uwe/Work/flutter-sdk/bin:$PATH` to use that copy. Use `MAPRISMA_PUB_OFFLINE=1` when running with the already resolved dependencies.

The service is a Python child speaking bounded versioned JSON lines on stdin and
stdout. No network listener is exposed. Frontend data cannot specify arbitrary
executables; agent launches use the registered adapter, selected real directory
and a cleaned environment. Folder selection does not grant permissions beyond
those of the process or its sandbox. Credentials are not transferred to Flutter.
The Unix PTY service currently targets Linux; other platforms need explicit work.

Development builds use `MAPRISMA_SOURCE` to find the Python checkout. Distribution
must bundle the service and resolve its location relative to the installed app.
Signed GTK UI add-ons, complete setup/installer guidance, durable jobs, model
tuning, map editing and remaining security/settings/help pages are still
migration work. The active plan carries the current parity inventory. Nothing installs or
publishes automatically.
