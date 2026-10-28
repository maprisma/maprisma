# Notes for coding agents

- **Flutter target (user decision, 2026-10-27):** `docs/plan-flutter.md` is the active
  UI migration plan. The final app must be Flutter; retain Python services where
  useful. The one-app/thin-launcher plan below still governs identity and delivery.
- **Current plan:** `docs/plan-one-app.md`: Asterism as the one app for every distribution, the Omarchy plugin
  as a thin launcher. It has Uwe's decisions, the facts with file paths, the next steps and the state of the repos.
- **Working with Codex and Claude:** work on `main` here. A new task gets `docs/plan-<topic>.md`; the
  implementing agent answers in `docs/plan-<topic>-responses.md`, a review is
  `docs/review-<reviewer>-<date>-<topic>.md` with its `-responses.md`. Finished plans, reviews and ideas move to
  `docs/history/` (links among them stay relative). Active: `plan-flutter.md`, `plan-one-app.md`.
- **Flutter checks:** `tools/flutter-dev check` (format, analyzer, tests), `tools/flutter-dev build` (isolated
  Devel build in `.flutter-previews/`, not launched). The remote `gtk` is the GTK repo
  `/mnt/Data/Projects/asterism`: never push this tree's `main` there.
- **One source:** shared code is edited only here; `tools/sync-plugin.py ~/.config/omarchy/plugins/ubruckhaus.ai-agents-map`
  copies it into the plugin (whose pre-commit hook refuses drift).
- **Before a commit:** `python3 -m unittest discover -s tests -q` and `tools/typecheck.sh` (0 errors).
- The core names no agent and no local LLM: their facts live in `adapters/` and `provider_*.py`.
- New UI texts in all 8 languages (`translations/*.json`); feature changes also in the manual (`docs/manual/`).
  Preserve source translation order and whitespace; append new keys instead of reserializing the file.
- Never read credential files (auth.json, .credentials.json); only check whether they exist.
- Nothing outward-facing (push, release, marketplace post, AUR upload) unless Uwe says so. Do not commit
  `docs/technical/` or the plugin toggle's LOCAL ONLY block.
