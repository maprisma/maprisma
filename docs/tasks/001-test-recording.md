# 001 Recording for a manual test

Author: Claude · Reviewer: Antigravity · Branch: task/001-test-recording

## Goal
Uwe tests Maprisma by hand on a fresh CachyOS install. Everything that happens is kept on /mnt/Data so it can
be reviewed afterwards: the protocol between GUI and core, the app's output and Uwe's notes. Nothing secret
reaches the recording.

## Routes
None changed. The recorder (`MAPRISMA_RECORD_PROTOCOL`, core.dart) blanks secrets before it writes a line:
values of secret-named fields (api_key, token, password, secret, authorization, cookie …), every value of an
`env` or `headers` map (names stay), the key of `agents.key_*`, and strings that look like a key (sk-…, AIza…,
ghp_…, xox…-, "Bearer …").

## UI
None. `tools/test-session.sh` (also copied to /mnt/Data/maprisma-test/start.sh): one folder per run under
/mnt/Data/maprisma-test/<date-time>/ with protocol.jsonl, app.log, system.txt (distribution, desktop, package
version) and notes.md (a checklist to fill in).

## Acceptance
- A recorded line never holds a secret from the cases above (core test `protocol_recording_test.dart`).
- Recording off: nothing is written, the route behaves as before.
- The script starts the installed `maprisma` (or an AppImage given as argument) and keeps its output.
