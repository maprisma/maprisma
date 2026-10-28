# Asterism Flutter frontend — migration in progress

The final Asterism application will use Flutter. This development frontend is the
first part of that migration; it is not yet a replacement for every GTK feature.
See [the migration plan](../docs/plan-flutter.md) for completion criteria and gaps.

Implemented source: responsive agent list/details, existing graph data with pan
and zoom, per-agent recent projects/pins/history-only deletion, project selection,
embedded PTY terminals, separate-terminal startup and close confirmation for
owned agents. Settings support language, global project folder, appearance and
map layers. Agent details include existing model/provider/plan/limit/today-usage
metadata. Eight-language UI assets reuse the application's translations.
Start uses a grouped submenu with searchable project history. Service startup
reuses the existing one-time settings migration and verifies signed agent/provider
add-ons; the local Add-ons page can enable/disable them. GTK-specific feature and
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
checks; Undo skips later edits. New server definitions, connection tests, skill
installation are still migration work. Provider connections/model switching now
use the same preview and backup flow, with private worker-side API contexts.
Undo restores configuration files only; it cannot undo API context changes.

The map refreshes external and owned session activity and opens delegated-session
metadata from badges or agent details. Claude, OpenCode, Codex, Copilot and Goose
are supported; other agents explicitly report tracking unavailable. Metadata
activity estimates do not establish that individual child processes are alive.

The Linux development build succeeds and the analyzer reports no issues. The
initial executable is `build/linux/x64/release/bundle/asterism`. Subsequent
`tools/flutter-dev build` calls create an isolated `.flutter-previews/` bundle and
print its absolute executable path, allowing an existing preview to stay open.
Keep each entire bundle directory together. Flutter widget runtime tests still need the host's loopback
socket permission. Do not infer complete feature parity from this initial build.

From the repository root:

```bash
tools/flutter-dev prepare
tools/flutter-dev check
tools/flutter-dev build
```

`tools/flutter-dev run` explicitly opens the development window. Do not run it
against the live desktop from an automated test. The original GTK entrypoint and
installed Omarchy plugin are unchanged. The development UI shares Asterism's
settings; avoid changing settings in both interfaces at the same time until
cross-process coordination is implemented.

On this machine the Arch Flutter wrapper needs FUSE, unavailable in the Codex
sandbox. A writable copy of the installed SDK is available at
`/home/uwe/Work/flutter-sdk`; prefix commands with
`PATH=/home/uwe/Work/flutter-sdk/bin:$PATH` to use that copy. Dependency downloads
and Flutter's test-runner loopback socket require a normal host terminal.

The service is a Python child speaking bounded versioned JSON lines on stdin and
stdout. No network listener is exposed. Frontend data cannot specify arbitrary
executables; agent launches use the registered adapter, selected real directory
and a cleaned environment. Folder selection does not grant permissions beyond
those of the process or its sandbox. Credentials are not transferred to Flutter.
The Unix PTY service currently targets Linux; other platforms need explicit work.

Development builds use `ASTERISM_SOURCE` to find the Python checkout. Distribution
must bundle the service and resolve its location relative to the installed app.
Signed GTK UI add-ons, setup, jobs, provider/model management, map editing and the
remaining application pages are still migration work. Nothing installs or
publishes automatically.
