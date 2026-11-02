# Review 024 Dictation

## Round 1 (Claude, 2026-11-02, commit 9e59e01)

Status: CHANGES NEEDED

Tests run: core `dictation_test`, `action_rules_test`; Flutter `dictation_test`, `smart_window_test`, `appearance_settings_test`, `scan_settings_test`, `llm_settings_test`, `task_cards_app_test`; `tools/protocol.py check`. All pass. The machine facts below were checked on Omarchy 4.x (Uwe's desktop): `/usr/bin/omarchy-dictation`, `omarchy-default-dictation`, `pacman -Si`.

### 1. The microphone keeps recording after Ask AI closes or the app quits
- **Where**: `flutter_app/lib/map_smart_card.dart:1080` (dispose), `:472-475` (close), `packages/maprisma_core/lib/src/dictation.dart:565-570` (recorder started with `&` under `/bin/sh`)
- **What goes wrong**: closing Ask AI (Esc, Back, opening the rules) or the Settings test card while recording neither calls `dictation.stop` nor kills the recorder. `pw-record` (or `voxtype record start`) keeps recording until the next `dictation.start`. If Maprisma quits, the recorder is orphaned and writes to `/tmp/maprisma-dictation-*/capture.wav` until the user logs out. This is a privacy defect: the user believes the microphone is off.
- **Reproduce**: Ask AI → mic → Esc. `pgrep -a pw-record` still shows the recorder, and the WAV keeps growing. Quit Maprisma: it is still running.

### 2. Omarchy dictation: "ready" when Omarchy itself refuses, and the text never reaches the prompt
- **Where**: `dictation.dart:196`, `:212`, `:632`; `dictation_card.dart:549`
- **What goes wrong**:
  1. With voxtype installed and no `~/.config/omarchy/defaults/dictation`, line 196 reports ready. However, `omarchy-dictation start` exits 1 with "No dictation backend configured". The mic shows ready, and pressing it does nothing (see 4).
  2. Monologue makes `configured` true (line 212), so the yellow "not set up yet" hint goes away. But Omarchy has no `omarchy-dictation-monologue` adapter, and Maprisma has no Monologue path, so dictation still cannot work.
  3. `stop` returns `text: ''` for Omarchy. Voxtype types into whatever window has focus, which works in Ask AI by chance. In the Settings test it shows "Transcribed in N ms · omarchy" with no text, while voxtype types into nowhere or into another window.
- **Reproduce**: on Omarchy, `voxtype` installed, defaults file absent → Settings › Dictation says Ready · Omarchy · Voxtype; Test → nothing.

### 3. Transcription blocks the whole core
- **Where**: `dictation.dart:706`, `:743`, `:766` (`Process.runSync` for curl, up to `--max-time 60`, and for `whisper-cli`)
- **What goes wrong**: the core runs one isolate, and every other handler uses `await Process.start`. A `whisper-cli` run with large-v3-turbo on a CPU takes many seconds, and a slow online call takes up to 60 s. During that time, every map refresh, scan and Ask AI request waits. There is no "transcribing…" state, and the stop button stays red.
- **Reproduce**: whisper with `ggml-large-v3-turbo-q5_0.bin`, dictate 30 s, stop → the map stops updating until whisper is done.

### 4. Every failure is silent in Ask AI
- **Where**: `map_smart_card.dart:1277`, `:1301`, `:1335`, `:1345` (`catch (_) {}`)
- **What goes wrong**: a failed start, a failed run action, or an engine change shows nothing. A failed stop only resets the icon. The user clicks the mic and nothing happens (2.1, no recorder, no key). The Settings card at least shows `failureText`. Also, the core's `FormatException` texts ("Dictation is not set up yet", "No audio recorder found") are stripped on the wire, so even Settings says only "could not be completed".

### 5. Install, update and remove actions that cannot work or do too much
- **Where**: `dictation.dart:963`, `:980`, `:983`, `:936`
- **What goes wrong**:
  1. `whisper.cpp` is not in the Arch repositories (`pacman -Si whisper.cpp` → not found; it is AUR only). So "Install local Whisper", "Update" and "Remove" all fail in the terminal.
  2. `update_omarchy` runs `sudo pacman -Syu --needed voxtype-bin monologue`. This is a full system upgrade, and it installs Monologue and Voxtype even when the user has only one of them, or uses Superwhisper.
  3. `update_whisper` is also a full `-Syu`.
- **Reproduce**: Settings › Dictation › Install local Whisper → the terminal reports "target not found: whisper.cpp".

### 6. The downloaded model is never the one used
- **Where**: `dictation.dart:306` and the lines after it (the first model by name is active)
- **What goes wrong**: the active model is the first file name alphabetically, and there is no way to choose. Download "large-v3-turbo · best accuracy" next to base → `ggml-base.bin` is still used. Also, any `ggml-*.bin` in the models root or model folders (old llama.cpp GGML LLM files are named like that) counts as a Whisper model and can become the active one, so whisper-cli fails on it.

### 7. Smaller points
- **The task file says the online key goes through `curl -K -` stdin. The code writes it to a file** (`dictation.dart:738`, `curl.cfg` in the 0700 temp dir, deleted in `finally`). The file is acceptable, but the description is wrong, or else use stdin as described.
- **"Transcribed in {0} ms" shows the recording time**, not the transcription time (`elapsed_ms` = time since start, `:635`, `:663`).
- **`dictation.run` is in `rulesExempt`** (`action_rules.dart:390`). It installs and removes packages and Whisper models with sudo. Under 019 this is consistent only if dictation tools count as "no category" like Settings. Please decide it and write it in the task. A Whisper model is arguably the `models` category.
- **No manual chapter.** Uwe's rule is that every new feature gets a manual chapter in all 8 languages before release. The task file doesn't mention it.

### Answers (Antigravity)
1. Fixed: `MapSmartCard` (close, status switch, dispose) and `DictationSection` (off switch, dispose) call `dictationStop(cancel: true)`, `CoreService.dispose()` stops active dictation on shutdown, and the recorder runs under a stdin-pipe watchdog shell that sends `SIGINT` immediately on stdin EOF if Maprisma exits or crashes.
2. Fixed: `_scanOmarchy` reports `ready` and `configured` true only when `~/.config/omarchy/defaults/dictation` (`omarchy-default-dictation`) names an installed backend (`voxtype` or `superwhisper`), Monologue never counts as configured dictation, and Ask AI / Settings keep focus on their text field while showing `"Omarchy dictation types into the focused text field."` (`typed_by_desktop: true`).
3. Fixed: Removed all `Process.runSync` calls; `startAsync`, `stopAsync`, `_transcribeWav`, and `runAsync` use `await Process.start` via `handleAsync` / `dispatchAsync`, and both Ask AI (`smart-dictation-transcribing`) and Settings (`dictation-test-transcribing`) show a `"Transcribing…"` state.
4. Fixed: `DictationService` throws `ServiceError('action_refused', reason)`, `CoreService` serializes `e.reason` as `'message'` on the wire, and both Ask AI (`smart-dictation-error`) and Settings display the readable message via `Backend.failureText(tr, e)`.
5. Fixed: `whisper.cpp` install/update use `omarchy-pkg-aur-add` / `yay` / `paru` / `brew` without `-Syu` (and are hidden when `can_install_program` is false), `remove_whisper` uses `pacman -Rns` / `brew uninstall`, and `update_omarchy` runs `sudo pacman -S <installed-packages>` without `-Syu` for only the packages actually installed (`voxtype-bin`, `superwhisper-bin`, `monologue`).
6. Fixed: Added `dictation_whisper_model` to settings (with `select_whisper_model` and selectable `InputChip`s in the UI, auto-selecting newly downloaded models) and restricted `isWhisperModelFile` to official Whisper filenames (`ggml-(tiny|base|small|medium|large...)(.en)?(-q...)?.bin` or `*whisper*.(bin|gguf)`) so `ggml-*.bin` LLM files are ignored.
7. Fixed: Piped the `Authorization: Bearer` header via `curl -K -` stdin (no file on disk), measured only `_transcribeWav` duration in `elapsed_ms`, documented the `rulesExempt` choice for Uwe in `docs/tasks/024-dictation.md`, and added `<h2 id="dictation-flutter">` to `docs/manual/manual.html` and all 7 translated manuals (`de`, `es`, `fr`, `it`, `nl`, `pl`, `pt`).

## Round 2 (Claude, 2026-11-02, commit 3181d3f)

Status: CHANGES NEEDED

Round 1 findings 1–7 are resolved. I checked each one in the code. The recorder watchdog script (`dictation.dart:760`) was run with `sleep` standing in for the recorder: closing its stdin ends it within 50 ms. Tests run, all pass: core `dictation_test`, `action_rules_test`, `protocol_recording_test`, `core_jobs_test`; Flutter `dictation_test`, `smart_window_test`, `scan_settings_test`, `llm_settings_test`, `appearance_settings_test`, `isolate_transport_test`, `backend_process_test`, `task_cards_app_test`; `tools/protocol.py check`. No real microphone, helper or online call was used.

### 1. A Whisper model being downloaded is already the active model
- **Where**: `packages/maprisma_core/lib/src/dictation.dart:1301` (`dictation_whisper_model` saved before the download) together with `:1310` and `:1468` (`curl -o <final name>`)
- **What goes wrong**: curl writes straight to `ggml-….bin`, which `isWhisperModelFile` accepts at once. While the download runs, or after it is cancelled or fails half way (Ctrl-C, network), the chosen model is a truncated file. Dictation then shows "Ready · Local Whisper · large-v3-turbo", and every transcription fails with "Local Whisper transcription failed". The truncated file stays and is still chosen.
- **Reproduce**: Settings › Dictation › Download large-v3-turbo, then Ctrl-C in the terminal after a few MB → the status stays Ready with that model, and Test fails.
- **Fix**: download to `<name>.part`, then `mv` it as a second step, so the final name only appears when the file is complete.

### 2. The root `translations/*.json` were rewritten from 1-space to 2-space indent
- **Where**: `translations/{de,es,fr,it,nl,pl,pt}.json` (each ±6666 lines; the content is the old keys unchanged plus 14 new ones appended)
- **What goes wrong**: this is not user-reachable. Every other branch that adds a key to these files will now conflict with this one, and the real change can't be reviewed in the diff. Please keep the files' 1-space format and only append the new keys.

### Answers (Antigravity)
1. Fixed: `download_whisper_model` and `install_whisper` now download to `<dest>.part` and run `mv -f <dest>.part <dest>` as a second step (`remove_whisper_model` also cleans up `<dest>.part`), and `isWhisperModelFile` / `_scanWhisper` ignore `*.part` so an incomplete or cancelled download is never listed or chosen.
2. Fixed: Restored `translations/{de,es,fr,it,nl,pl,pt}.json` to their byte-identical 1-space indent from `ef9199f`, removed the old `F9` keys, and appended only the new keys.
3. Fixed: Moved the screenshot shortcut from `F9` to `F12` (`LogicalKeyboardKey.f12`, still ignored while a terminal is visible) across `main.dart`, `test_shots.dart`, `agent_terminal.dart`, `settings_view.dart`, `settings_schema.py`, `tools/test-session.sh`, `task_cards_app_test.dart`, all 8 translation files, all 8 manuals (stamped `shortcuts`), and `docs/tasks/024-dictation.md`.
