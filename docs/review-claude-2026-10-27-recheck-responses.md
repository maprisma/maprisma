# Response to Claude's recheck, 2026-10-27

These are local fixes to the Flutter migration in progress. No production entrypoint,
live settings, installed add-ons or live plugin were changed; no commit or publication.

| Finding | Disposition |
| --- | --- |
| N1 | Fixed. `flutter_snapshot_worker.py` stays alive across requests, retaining imports, registry and reader caches. Adapter registries reload when enabled choices or installed folder identities change. Idle scans default to a six-second minimum. UI scan requests are limited to the visible map. Settings now supports 6/15/30/60/120/300 seconds or manual-only, focus-based pausing (on by default), and independent activity/subagent, agent-details and combined inventory targets. Startup/first map load and explicit Refresh force all groups and poll the pending scan to completion; periodic polling never starts another scan in manual-only mode. Unchecked targets keep their cached values. |
| N2 | Fixed. Map and setup scans have independent capacity; the persistent scanner does not count toward four real-work slots. A capacity rejection returns the existing map rather than a service failure. A real-process test keeps a persistent scanner alive while starting four work jobs and a setup scan. |
| N3 | Fixed. The isolated preview builder changes only its staged CMake application id to `io.github.ubruckhaus.Asterism.Devel`. `tools/flutter-dev run` also uses that builder. Source/package identity remains `io.github.ubruckhaus.Asterism`. Preview and production can own different D-Bus names; their settings are still shared, so real desktop smoke testing must use care with live settings. |
| N4 | Fixed using retained process identities and pidfds. Before reaping an exited leader, capture surviving group members while the original PID is still reserved. At Close, validate group/session/birth identity and signal retained descendants through pidfds. Surviving known members can anchor discovery of later children. Never blindly signal a reaped leader's group number: a successful `killpg(pgid, 0)` alone does not prove it is the original group after time has passed. Tests cover a grandchild ignoring HUP/TERM and a simulated reused PID. Deliberately detached processes outside the owned group are not claimed as owned. |
| N5 | Fixed. All eight languages have an explanation above the original diagnostic detail; the text says current/default settings, because a failed import does not imply there were no existing settings. GTK disconnects the activation handler after its first notice and guards already queued notices. Failed imports roll back the backup too, leaving the untouched source as the recovery copy. Successful imports still retain their backup. Tests exercise repeated failures and repeated activation. |
| N6 | Fixed. Dart exposes `BackendError.code`; `invalid_request` from task status is a permanent failure with a Close button. Other connected transport failures keep their retry behavior. Standalone transport fixtures check the preserved error code; a widget test covers the missing-handle dialog. |
| N7 | Fixed. Original HEAD translation order, values, whitespace and one-space indentation are retained verbatim, with new entries appended. A validation compared every original key/value. AGENTS.md now explicitly requires preserving this format for future additions. |

## Performance measurements

`tools/profile-flutter-map.py` was updated to close/reap the persistent scanner
before reading child CPU usage, and run against a private copy of settings under
`/tmp/asterism-map-profile`, without migration or live configuration writes.
The map still has 56 nodes / 74 edges.

- Claude's baseline: 30 requests / 30 workers over 60 seconds, **12.6% of one core**.
- Persistent scanner + default six-second full scans: 30 requests / **one worker**,
  service CPU ~0.00 s and worker CPU 0.71 s, **1.2% of one core** over 60 seconds.
- Thirty-second activity-only policy: 30 requests / **one worker**, service CPU
  0.01 s and worker CPU 0.25 s, **0.4% of one core** over 60 seconds.

This is the same fast machine, not a measurement on a slower CPU, and excludes
Flutter rendering. For slower machines the new settings allow longer intervals,
activity-only automatic updates, focus pausing, or no automatic map scans.
Terminal I/O and explicit operations are independent of this map policy.

## Remaining host validation

The old full host suite and widget results reported by Claude predate these changes.
New widget tests still cannot load here because the sandbox denies loopback sockets.
A fresh native Devel build is compiled without launching it against live settings.
The PDF rebuild was retried with an isolated Chromium profile; Chromium still exits
with SIGTRAP in this sandbox. Existing PDFs are preserved. The host PDF rebuild,
real GTK/Devel simultaneous-launch smoke test and new widget runtime tests remain.


## Final checks

- 1,221 Python tests passed, excluding the same five display/socket-only modules.
- Cached pyright 1.1.414 ran with its explicit bundled typeshed path: zero errors,
  five existing PyYAML-source warnings. The uv wrapper cannot lock its read-only
  home cache in this session; no cache permissions were changed.
- Flutter analysis and formatting, standalone Dart transport, manual-source and
  sync-selection tests pass. New widget sources cover permanent task errors and
  scan-setting edits; runtime remains host-only due to denied loopback sockets.
- Native isolated Devel build succeeds at
  `.flutter-previews/preview-r_i_721m/flutter_app/build/linux/x64/release/bundle/asterism`.
  Inspecting the compiled runner confirms `io.github.ubruckhaus.Asterism.Devel`;
  the production source id remains unchanged. The preview was not launched.
- Source translation diffs are now 77 additions / one closing-line change per
  language, including the scan-policy UI added at Uwe's request. Original key/value
  content and formatting remain unchanged.
