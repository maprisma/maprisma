# 072 The AI helpers of the other Maprisma apps (`data/helpers.json`)

Author: Claude · Reviewer: Antigravity · Branch: task/072-helpers-catalog

## Goal
Every Maprisma app's "AI helper" choice offers any installed agent that can do its job, from one
source: Maprisma's adapters. `tools/export-helpers.py` writes their `[ask]` (one prompt, one answer,
no tools or read-only) and `[task]` (interactive in a terminal with a first prompt) to
`data/helpers.json`, installed as `/usr/lib/maprisma/data/helpers.json`. Format and rules:
`docs/adapter-format.md` (The helpers export).

## Routes
None.

## Adapters
New entries come from each agent's official documentation (the source URL is a comment next to
each); only Claude Code is installed on the PC they were written on (checked with `claude --help`).
Entries not yet tried with the agent say `verified = false`: exported with `"verified": false`, not
used by Maprisma itself (`adapter_data.in_use`, `Adapter.inUse`), so nothing in the app changes.

| Agent | task | ask |
|---|---|---|
| claude | `claude {prompt}` (as before) | as before (no tools) |
| codex | as before | as before (read-only sandbox) |
| gemini | `gemini -i {prompt}` | `gemini --approval-mode default -o text -p {prompt}` (approval-needing tools denied headless; not plan mode, which turns to YOLO) |
| agy | `agy -i {prompt}` | `agy -p {prompt} --output-format text --mode=plan --sandbox` |
| opencode | `opencode --prompt {prompt}` (1.x docs; 2.x documents it only for `opencode mini`) | none for the helpers (`helper = false`: `run` allows its shell) |
| cursor-agent | `cursor-agent {prompt}` | `cursor-agent -p --mode ask --sandbox enabled --output-format text {prompt}` |
| copilot | `copilot -i {prompt}` | `copilot -p {prompt} -s --no-ask-user --deny-tool=shell --deny-tool=write --deny-tool=url --deny-tool=memory` |
| goose | `goose run -t {prompt} -s` | none: only the environment variable `GOOSE_MODE=chat` keeps it from tools |
| grok | none: no first prompt for its TUI | `grok --no-auto-update -p {prompt} --output-format plain --permission-mode dontAsk --sandbox read-only` |
| hermes | `hermes chat -q {prompt}` | as before (`-t todo --ignore-rules -z`) |
| omp | `omp {prompt}` | `omp -p --no-tools --no-extensions {prompt}` |
| openclaw | `openclaw chat --message {prompt}` | `openclaw agent exec --config-override {"tools":{"deny":["*"]}} {prompt}` |
| pi | `pi -- {prompt}` | as before (`-p --no-tools --no-approve`) |
| crush, dsh, bionic, muse | none | none (a comment in each adapter says why) |

## UI
None in Maprisma. The other apps read the file.

## Packaging
`tools/build-release.py` checks the file is up to date (`--check`) and copies it into the bundle's
`data/`, which the AUR package installs to `/usr/lib/maprisma` (so `/usr/lib/maprisma/data/helpers.json`)
and the AppImage to `usr/lib/maprisma`; the development preview gets it too. It is JSON, so
`tools/check-bundle.py` is content.

## Acceptance
`tests/test_export_helpers.py` (format, order, entries, version bump, the committed file up to
date, unverified entries left out of the app); `packages/maprisma_core/test/adapters_test.dart`
(`Adapter.inUse`); the adapter snapshots unchanged; `tools/test-changed --base main` green apart
from the failures main has too.

## Open
- Try each `verified = false` entry with the agent installed and remove the line (then Maprisma uses
  it as well: Test button, "Do it with …" needs a `closed.task` too).
- OpenCode 2.x: whether `opencode --prompt` still works or only `opencode mini --prompt`.
