# Responses to Claude's 2026-10-28 review

## E1 — Welcome actions and the failing widget test

Fixed the layout rather than enlarging the test surface. Welcome has a scrolling
content area above a fixed action row: **Switch on** and **Later** stay visible
on short windows. The pending-detection test checks both buttons are hit-testable
at the default test size; applying stays disabled until detection finishes.

## E2 — Preserve `current` for subsequent updates

Fixed for both providers. Discovery keeps the resolved native binary for identity
checks and deduplication, plus its launch path and lstat/readlink identities for
symbolic-link components. Provider rules prefer `current/llama-server` and
`current/bin/ollama` (or `current/ollama`). A direct-build discovery cannot replace
an alias record. The wrapper and explicit version check use the launch path.

Before preview, compatibility checks and Apply, the alias must still resolve to
the reviewed binary; link identities and target stamps must match. Foreign-owned
links and links pointing outside the mount are rejected. Retargeting or recreating
`current` before Apply invalidates the plan. After Apply, intentionally updating
`current` takes effect without regenerating the wrapper. New tests cover both
providers, stale/escaped aliases and removing an old build after updating.

## E3 — Named, home-relative services

Fixed. Description includes the provider name. ExecStart uses the trusted `%h`
specifier for `.local/bin/<command>`, matching EnvironmentFile. Other paths retain
percent/dollar escaping; arbitrary metadata cannot opt into a specifier. The
wrapper's model-preset argument also uses the runtime user's `$HOME`.

## E4 — Fresh tuning baseline; no guessed GPU index

The generated llama.cpp configuration includes a new `models.ini` with `[*]` /
`gpu-layers = all`, referenced by `--models-preset`. It participates in preview,
absence checks and Undo. Existing presets/tuning are never overwritten. The
preview explains that tuning starts fresh and GPU selection uses runtime defaults,
which must be checked before loading on a multi-GPU PC.

**Automatic device pinning is intentionally deferred.** `gpu_stack.Stack`
describes driver availability and `gpu_usage.discrete_gpu()` selects a sysfs card;
neither establishes that binary's ROCm/CUDA device indices. Guessing `ROCm0` could
pin the wrong card. Selectable runtime IDs require a separately disclosed and
confirmed enumeration action; Check program currently authorizes only `--version`.
No unannounced probe or old GPU binding was introduced. This part of the suggestion
remains a follow-up, rather than being reported as implemented.

## E5 — Discovery explanations

- GGUF results warn that speech/vision models may be present. Names alone do not
  establish language-model compatibility. This implements the suggested hint
  approach without reading every header.
- Depth, entry, time, result and response-size limits are reported separately.
  Reaching depth 5 says deeper folders were skipped; it does not imply the whole
  scan stopped early.
- Skipped foreign-owned folders are explained. Recognizable candidate paths
  directly encountered under another UID are listed separately and cannot be
  adopted. Inaccessible trees are not claimed to have been searched.
- Cross-filesystem/nested-subvolume exclusions are shown, including btrfs. They
  need their own mounted entry point for scanning. Ownership, mount options and
  fstab are unchanged.

## E6 — Online-service consent

Fixed. The prompt preview says the chosen agent **and, for an online model, its
service** receive the overview, including folder paths. The token/plan notice and
explicit confirmation remain. A new widget test checks cancelling this consent
never starts a helper.

## Scope and validation

The idea file records the requested entry points, wrapper-plus-unit scope, Flutter
target and simplification-help expansion, distinguishing explicit user requests
from implementation choices. Strings and development-manual notes cover all eight
languages; existing translation values are preserved.

Validation: **1,285 Python tests pass**, excluding the same five host-only
GTK/socket modules. The discovery suite now has 36 tests, including seven new
regressions for this review. Pyright reports zero errors and five pre-existing
PyYAML-source warnings. Flutter analysis is clean; Dart transport, translation
uniqueness/preservation, manual checks, sync-selection tests and `git diff --check`
pass. Generated wrappers pass `sh -n`. A read-only real-disk scan resolves both
runtimes through their validated `current` links and reports only the depth limit.

Flutter widget execution is blocked by the sandbox's denied local server socket;
therefore the Welcome test repair and new online-consent test need a host rerun.
`systemd-analyze --user verify` is also blocked here by socket restrictions; host
verification of the revised home-relative units remains pending. Prior host
verification of the original units does not substitute for this recheck.

Built preview:
`.flutter-previews/preview-9c7exvqy/flutter_app/build/linux/x64/release/bundle/asterism`.
It uses this repository's Python backend. No live configuration was changed, and
no discovered program or AI helper was executed. Manual PDF rebuilding, desktop
smoke tests and final feature-parity review remain open as previously recorded.
