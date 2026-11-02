# 024 Dictation in Ask AI and Settings

Author: Antigravity · Reviewer: Claude · Branch: task/024-dictation, on task/023-common-look

Uwe, 2026-11-02: voice dictation in Ask AI and a Dictation section card in Settings. Default is on (`dictation: true`), with a yellow indicator when dictation is on and no backend is set up yet. Supports all four scenarios: Omarchy's built-in dictation and Monologue when running on Omarchy, local Whisper (`whisper.cpp`), a speech model on a local LLM runtime, and a connected online provider (with a clear cost and privacy hint). Both Ask AI and the Settings card allow setting up, updating, removing and managing dictation, and the Settings card includes an inline test feature.

## Backends and priority (`dictation_engine: auto | omarchy | whisper | local | online`)
1. **Omarchy dictation / Monologue (`omarchy`)** — on Omarchy (`desktop.name == 'omarchy'`):
   - Uses `/usr/bin/omarchy-dictation` (`start` / `stop`), `/usr/bin/omarchy-default-dictation` (`voxtype` or `superwhisper` in `~/.config/omarchy/defaults/dictation`), `/usr/bin/omarchy-dictation-use`, and `/usr/bin/monologue`.
   - When not installed or configured yet, offers guided terminal actions for `omarchy-install-dictation-voxtype`, `omarchy-install-dictation-superwhisper`, `omarchy-pkg-add monologue` (`sudo pacman -S --needed monologue`), `omarchy-voxtype-model`, `omarchy-voxtype-config`, updates (`sudo pacman -Syu --needed voxtype-bin monologue`), and removal (`omarchy-remove-dictation-voxtype`, `omarchy-remove-dictation-superwhisper`, `omarchy-pkg-drop monologue`).
2. **Local Whisper (`whisper`)** — offline, 0 tokens:
   - Uses `whisper-cli` / `whisper` in `PATH` or `~/.local/bin` with a local Whisper model (`ggml-*.bin` or `*whisper*.gguf`) in `~/.local/share/maprisma/whisper/models`, `~/.local/share/voxtype/models`, `~/.cache/whisper`, or the configured model folders.
   - Offers installing `whisper.cpp`, downloading a starter model (`ggml-base.bin`, `ggml-small.bin`, or `ggml-large-v3-turbo-q5_0.bin`), updating `whisper.cpp`, and removing downloaded models or `whisper.cpp`.
3. **Local LLM speech model (`local`)** — offline, 0 tokens:
   - Uses an installed local LLM runtime (`llamacpp`, `vllm`, `ollama`, `lmstudio`) that has a speech/audio model (`voiceRe`) or serves `/v1/audio/transcriptions` locally on loopback.
4. **Online provider (`online`)** — paid / API credit:
   - Uses a configured online transcription API key (`OPENAI_API_KEY` / `GROQ_API_KEY` from environment or `~/.codex/.env`, without reading credential files or exposing keys).
   - Shows a clear cost and privacy hint in both Ask AI and Settings whenever online dictation is active or selected, with a one-click option to install local Whisper or Omarchy dictation instead.

## Storage and routes
- Settings: `dictation` (`bool`, default `true`) and `dictation_engine` (`'auto' | 'omarchy' | 'whisper' | 'local' | 'online'`, default `'auto'`) in `settings_schema.py`, `flutter_backend.py` (`UI_SETTINGS`), `settings.dart` (`uiSettings`), `core_assets.g.dart`, and `routes.json`.
- Routes: `dictation.snapshot` (`read`), `dictation.start` (`change`), `dictation.stop` (`change`), `dictation.run` (`change`).
