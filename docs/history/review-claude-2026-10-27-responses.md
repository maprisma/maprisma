# Response to Claude's interim Flutter review

Local fixes, 2026-10-27. No commit, installation, plugin sync, push or release.
The migration remains in progress. This responds to the interim review, not the
final migration acceptance review.

| Item | Disposition and resulting behavior |
| --- | --- |
| H1 | Fixed. Sync excludes `flutter_*.py`, their tests and the Flutter-only PTY module/tests. A regression checks the selected file set. GTK-shared identity/project/metadata modules remain included. |
| H2 | Fixed. Development uses the explicit source define; otherwise the backend must exist alongside the resolved executable. Cwd is never used. The interpreter is `/usr/bin/python3`. |
| M1 | Fixed startup failure. Import errors are logged, Flutter exposes the reason in its window, and GTK presents the reason after activation. Neither app aborts solely because the legacy import failed. Migration accepts resolved home/config ancestors while retaining no-follow checks below those trusted roots. Existing source settings remain untouched; failed imports can be retried on later starts. |
| M2 | Fixed interruption. Shutdown drains and waits up to 30 seconds for commit workers; it never signals an unfinished commit. An exceptionally slow private commit finishes detached. The UI awaits service shutdown before destroying the window. Transient task-status failures retry while the service is connected. Backups remain on disk; an Undo token is not promised across application restarts. |
| M3 | Fixed. Null-id diagnostic errors are ignored. Oversized requests are drained through their newline and the next request is accepted. Fatal transport failures explicitly terminate the backend, and terminal tabs report that the session ended. Reconnect refuses while an owned terminal is still considered active; once disconnected tabs observe the failure, refresh can reconnect. |
| M4 | Fixed the identified bottlenecks. Map construction runs in an isolated worker and returns the last completed snapshot while scanning. All connection file commits use a worker. Read-only calls have method-specific timeouts; session starts, input writes and commit starts retain correlation until completion/disconnect. Terminal polling retries transient errors with a delay and preserves pending resize state. The first map result can take a refresh cycle to appear. |
| M5 | Fixed. Input after child exit returns accepted=0/ended=true and final PTY output remains readable. |
| M6 | Fixed. Window-close requests are no longer dropped merely because a refresh/dialog is busy. |
| M7 | Fixed. Stopping a live embedded agent requires confirmation. Closing an ended tab does not. |
| M8 | Rejected as a current distribution defect. These changes are to built-in adapters in the same application tree, not a signed add-on release. Changing this tree cannot make an already installed older app understand a new format. Any future separately distributed adapter add-on must declare a compatible minimum application/API version before publication; no such publication is authorized here. |
| L1 | Fixed. Session and task cleanup continue after `TimeoutExpired`, including after kill escalation. |
| L2 | Fixed. Unknown handles are invalid requests. Queue rejection preserves previews; failed/refused Undo retains its token. Handles are consumed after successful operations. |
| L3 | Fixed. An exited PTY leader has a one-second output-drain grace period, after which descendants retaining the slave no longer keep its tab running. |
| L4 | Fixed. Dart framing caps a response at 1 MiB before decoding. Terminal input caps pending bytes at 256 KiB and explicitly rejects a paste that would exceed the cap. |
| L5 | Fixed. Child-stdin errors are observed; window destruction awaits shutdown. A fallback timer is no longer the only opportunity for the service to clean up. |
| L6 | Fixed. New and legacy saved project histories retain the newest 50 entries per agent. The settings byte cap still protects unusually large other values. Manual sources explain the limit in eight languages. |
| L7 | Fixed reader behavior. Copilot appends reuse parsed metadata and an incomplete-line buffer, preserving the session cwd. Resolved home ancestors work; link-based unsupported storage is reported unavailable by Flutter activity. The isolated map worker currently starts afresh for each scan, so its reader cache does not persist between workers; this remaining efficiency limit does not block terminal traffic. |
| L8 | Fixed by documenting the Asterism fork directly in `i18n.py`; the ai_core settings integration must survive upstream helper updates. |
| L9 | Flutter preview paragraphs removed from all production manual sources. PDF regeneration attempted but blocked: Chromium terminates with SIGTRAP in this sandbox. Existing PDFs were preserved; rebuild on the host remains required. |
| L10 | Fixed. GTK AppImage assembly excludes Flutter service and PTY modules. |
| L11 | Fixed. `Running` is included by the Flutter translation generator for all eight languages. New terminal diagnostics are translated too. |
| L12 | Fixed. Async mounted guards added. Linux uses the existing application ID with GApplication uniqueness and presents its existing window on repeat activation. Native title is Asterism. This still needs a real desktop/D-Bus smoke test. |
| L13 | Accepted as intended, per Uwe's review note. Automatic Omarchy integration stays. The Flutter runner now requests singleton behavior; the final thin-launcher handoff remains part of the migration plan. |

## Regression and validation notes

Regression cases cover failed migration startup, oversized-request recovery,
null-id transport errors, terminal input after exit, cleanup timeouts, commit
shutdown, rejected queues, slow map scans with concurrent terminal reads, history
trimming, and incremental Copilot metadata. Existing map serialization tests now
exercise the extracted map builder; a separate test covers cached async dispatch.
The project-start widget tests await menu-close callbacks.

The full Python command was attempted and crashed in GTK widget tests without a
usable display. Running every module in a separate process identified the five
host-only modules: `test_add_mcp_test_button`, `test_back_keys`,
`test_herdr_state`, `test_loopback_stream`, `test_review_fixes`.
Flutter widget execution is blocked before test loading by denied loopback socket
creation. Host widget execution and manual PDF rebuild remain outstanding.

Final sandbox-compatible aggregate: **1,181 tests passed**, excluding the five
host-only modules above. A subsequently added resolved-home/config-link test also
passes (19 migration/identity tests). Python typechecking: **0 errors**, with the
five existing PyYAML-source warnings. Standalone Dart transport checks pass.
Manual-source and translation checks pass. Flutter formatting and analysis pass.

An isolated Linux release-mode development build succeeded at
`.flutter-previews/preview-zag2l7ax/flutter_app/build/linux/x64/release/bundle/asterism`.
It was not launched, so validation did not run migration against live settings.
