# 024 Dictation in Ask AI and Settings

Author: Antigravity · Reviewer: Claude · Branch: task/024-dictation, on task/023-common-look

Uwe, 2026-11-02: voice dictation in Ask AI and a Dictation section card in Settings. Default is on (`dictation: true`), with a yellow indicator when dictation is on and no backend is set up yet. Supports all four scenarios: Omarchy's built-in dictation (plus Monologue management) when running on Omarchy, local Whisper (`whisper.cpp`), a speech model on a local LLM runtime, and a connected online provider (with a clear cost and privacy hint). Both Ask AI and the Settings card allow setting up, updating, removing and managing dictation, and the Settings card includes an inline test feature.

## Backends and priority (`dictation_engine: auto | omarchy | whisper | local | online`)
1. **Omarchy dictation & Monologue (`omarchy`)** — on Omarchy (`desktop.name == 'omarchy'`):
   - Uses `/usr/bin/omarchy-dictation` (`start` / `stop`), `/usr/bin/omarchy-default-dictation` (`voxtype` or `superwhisper` in `~/.config/omarchy/defaults/dictation`), and `/usr/bin/omarchy-dictation-use`.
   - Ready and configured only when `omarchy-default-dictation` names an installed backend (`voxtype` or `superwhisper`). Voxtype and Superwhisper type recognised speech directly into the focused text field (`typed_by_desktop: true`); Ask AI and the Settings test keep focus on their text field and note this behaviour.
   - Monologue (`/usr/bin/monologue`) can be installed, opened and removed from the card, but is not an `omarchy-dictation` backend and does not count as configured dictation.
   - Guided terminal actions: `omarchy-install-dictation-voxtype`, `omarchy-install-dictation-superwhisper`, `omarchy-pkg-add monologue` (`sudo pacman -S --needed monologue`), `omarchy-voxtype-model`, `omarchy-voxtype-config`, `update_omarchy` (`sudo pacman -S <installed-packages>` without `-Syu`, only for packages actually installed), and removal (`omarchy-remove-dictation-voxtype`, `omarchy-remove-dictation-superwhisper`, `omarchy-pkg-drop monologue`).
2. **Local Whisper (`whisper`)** — offline, 0 tokens:
   - Uses `whisper-cli` / `whisper` in `PATH` or `~/.local/bin` with a local Whisper model in `~/.local/share/maprisma/whisper/models`, `~/.local/share/voxtype/models`, `~/.cache/whisper`, or the configured model folders. Only Whisper model filenames (`ggml-(tiny|base|small|medium|large...)(.en)?(-q...)?.bin` or `*whisper*.(bin|gguf)`) are matched; general `ggml-*.bin` LLM files are ignored.
   - Lets the user choose the active Whisper model when multiple models are downloaded (stored in `dictation_whisper_model` in settings).
   - Offers installing/updating/removing `whisper.cpp` via `omarchy-pkg-aur-add` / `yay` / `paru` (AUR on Arch, without `-Syu`) or `brew` when available (`can_install_program`), plus downloading and removing Whisper models (`ggml-base.bin`, `ggml-small.bin`, `ggml-large-v3-turbo-q5_0.bin`).
3. **Local LLM speech model (`local`)** — offline, 0 tokens:
   - Uses an installed local LLM runtime (`llamacpp`, `vllm`, `ollama`, `lmstudio`) that has a speech/audio model (`voiceRe`) or serves `/v1/audio/transcriptions` locally on loopback.
4. **Online provider (`online`)** — paid / API credit:
   - Uses a configured online transcription API key (`OPENAI_API_KEY` / `GROQ_API_KEY` from environment or `~/.codex/.env`, without reading credential files or exposing keys). The `Authorization: Bearer` header is piped to `curl -K -` on stdin so it never appears in `ps` or on disk.
   - Shows a clear cost and privacy hint in both Ask AI and Settings whenever online dictation is active or selected, with a one-click option to install local Whisper or Omarchy dictation instead.

## Lifecycle, async transcription, and error reporting
- Audio capture (`pw-record` / `arecord` / `ffmpeg`) runs under a stdin-pipe watchdog shell: closing the stdin pipe on `dictation.stop`, `dictation.stop(cancel: true)`, `CoreService.dispose()`, or unexpected process exit immediately sends `SIGINT` to the recorder so no orphaned `pw-record` can survive closing Ask AI, leaving Settings, or quitting Maprisma.
- All subprocess calls (`omarchy-dictation`, recorder, `whisper-cli`, `curl`) are asynchronous (`await Process.start`) on `handleAsync` / `dispatchAsync`; both Ask AI and Settings show a `Transcribing…` state while transcription runs, and `elapsed_ms` measures only the transcription step.
- User-facing failures throw `ServiceError('action_refused', reason)` and are shown in both Ask AI and Settings via `Backend.failureText`.

## Storage, routes, and manual
- Settings: `dictation` (`bool`, default `true`), `dictation_engine` (`'auto' | 'omarchy' | 'whisper' | 'local' | 'online'`, default `'auto'`), and `dictation_whisper_model` (`string`, default `''`) in `settings_schema.py`, `flutter_backend.py` (`UI_SETTINGS`), `settings.dart` (`uiSettings`), `core_assets.g.dart`, and `routes.json`.
- Routes: `dictation.snapshot` (`read`), `dictation.start` (`change`), `dictation.stop` (`change`), `dictation.run` (`change`).
- User manual: `<h2 id="dictation-flutter">` in `docs/manual/manual.html` and all 7 translations (`de`, `es`, `fr`, `it`, `nl`, `pl`, `pt`).

## Decision for Uwe: Action Rules (019) and `dictation.run`
- `dictation.start`, `dictation.stop`, and `dictation.run` are currently listed in `rulesExempt` (`packages/maprisma_core/lib/src/action_rules.dart`), treating dictation setup and Whisper model downloads in `~/.local/share/maprisma/whisper/models` as personal app/desktop settings (like `settings.update`) rather than AI map mutations (`agents`, `providers`, `models`, `mcp`, `skills`).
- **Question for Uwe**: Should `dictation.run` stay in `rulesExempt` as part of personal Settings, or should `download_whisper_model` / `remove_whisper_model` (and/or package install/update/remove actions in `dictation.run`) be checked against the `models` (or `providers`) category in "What may be done" (`019`)?
