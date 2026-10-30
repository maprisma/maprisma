# Notes for coding agents

- **Flutter target (user decision, 2026-10-27):** `docs/plan-flutter.md` is the active
  UI migration plan. The final app must be Flutter, its service the Dart core (Python only as the
  reference, see below). The one-app/thin-launcher plan below still governs identity and delivery.
- **Current plan:** `docs/plan-one-app.md`: Maprisma (called Asterism until 2026-10-30) as the one app for every distribution, the Omarchy plugin
  as a thin launcher. It has Uwe's decisions, the facts with file paths, the next steps and the state of the repos.
- **GTK app frozen (Uwe, 2026-10-28):** Flutter replaces it on Linux too. The GTK repo gets fixes only, no
  new features; new work happens here (plan: `docs/plan-flutter-dart-core.md`).
- **Flutter only, Python for testing (Uwe, 2026-10-28):** the shipped app contains no Python; the service is
  ported to Dart (`docs/plan-flutter-dart-core.md`), Python stays as the reference and test oracle.
- **Python is reference only (phase 7, 2026-10-30):** every `*.py` here (and `adapters/*.py`) is the
  reference implementation for the differential and parity tests; nothing of it runs in the app. The app's
  service is the Dart core (`packages/asterism_core`); a route it does not know is refused. The GTK UI was
  removed from this tree; its frozen copy is `/mnt/Data/Projects/omarchy-ai-agents-map`. New features are
  Dart only; change a Python module only to keep a reference in step with a port.
- **Release gate:** `tools/check-bundle.py` (run by `tools/flutter-dev build`): no `.py`, no Python
  executable or service marker in the bundle, none in the Dart code of the app or the core.
- **macOS later:** `docs/plan-macos.md`. Not before Linux is completely done and Uwe's OK; meanwhile keep
  new platform code behind the desktop adapter.
- **Working with Codex and Claude:** work on `main` here. A new task gets `docs/plan-<topic>.md`; the
  implementing agent answers in `docs/plan-<topic>-responses.md`, a review is
  `docs/review-<reviewer>-<date>-<topic>.md` with its `-responses.md`. Finished plans, reviews and ideas move to
  `docs/history/` (links among them stay relative). Active: `plan-flutter.md`, `plan-one-app.md`, `plan-flutter-dart-core.md`, `plan-macos.md` (later).
- **Flutter checks:** `tools/flutter-dev check` (format, analyzer, tests), `tools/flutter-dev build` (isolated
  Devel build in `.flutter-previews/`, not launched). Naming: `docs/plan-naming.md`.
- **A clean cut (Uwe, 2026-10-30):** Maprisma knows nothing of the GTK app AI Agents Map: no shared code,
  names, folders, settings import, remote or sync. The plugin repo `/mnt/Data/Projects/omarchy-ai-agents-map`
  is its own GTK source. Maprisma only still recognises what the GTK app left on a user's PC (its install
  marker `.ai-agents-map`, units "installed by AI Agents Map", `# Connected by Asterism`) and copies the
  Asterism folders once (`legacy_move.dart`).
- **Before a commit:** `python3 -m unittest discover -s tests -q` and `tools/typecheck.sh` (0 errors).
- The core names no agent and no local LLM: their facts live in `adapters/` and `provider_*.py`.
- New UI texts in all 8 languages (`translations/*.json`); feature changes also in the manual (`docs/manual/`).
  Preserve source translation order and whitespace; append new keys instead of reserializing the file.
- Never read credential files (auth.json, .credentials.json); only check whether they exist.
- Nothing outward-facing (push, release, marketplace post, AUR upload) unless Uwe says so. Do not commit
  `docs/technical/` or the plugin toggle's LOCAL ONLY block.
