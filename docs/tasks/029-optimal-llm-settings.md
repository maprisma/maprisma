# 029 Always the best context and settings for each local model

Author: Claude · Reviewer: Antigravity · Branch: task/029-optimal-llm-settings

## Goal
Every llama.cpp model runs with the context and settings that are best for this graphics card and the
llama.cpp build the service really runs (ROCm or Vulkan): worked out by measuring, not guessed, and set
again when the build changes. Uwe's choices (2026-11-03): measure; KV cache q8_0; tune the build in use
(switching builds stays the user's choice).

## What is wrong today (checked 2026-11-03, Uwe's PC: RX 7900 XTX, Vulkan build b12078)
- A new llama.cpp model never gets its best context. `connectExtra` (`context.dart:815`) and the
  reference's `auto_context` (`llm_engine.py:188`) keep a context "already set", and `llamaSettings` /
  `llama_settings` count the catch-all `[*] ctx-size` as the model's own. With `[*] ctx-size = 8192` in
  `~/.config/llama.cpp/models.ini` every new model stays at 8192, though the docstring says "a model
  without a context of its own gets the best one".
- After a download nothing sizes the model: `set_new_contexts` (`llm_engine.py:237`) is never called, and
  the Dart core has no counterpart.
- The context is calculated from the GGUF header with a fixed reserve (`context.dart:13`, 1.5 GiB) and the
  KV cache type from models.ini (f16 when none). Flash attention, KV cache type and batch sizes are never
  worked out; only an AI can be asked for advice (`models.tuning_ask`).
- The build is read from `llama-server` on PATH (`llamaDevices`), not from what the service runs. Here
  `~/.local/bin/llama-server` and the unit's drop-in both run `/mnt/Data/Ai/llama.cpp-vulkan/current`; the
  ROCm build next to it needs its runtime's `LD_LIBRARY_PATH` (a drop-in `Environment=`).

## The rule
1. **Own section only.** For llama.cpp, a context counts as set only in the model's own models.ini
   section. `[*]` stays a fallback for models the app has not sized. Dart core and Python reference.
2. **q8_0 and flash attention.** A model the app sizes gets, in its own section: `ctx-size`,
   `cache-type-k = q8_0`, `cache-type-v = q8_0`, `flash-attn = on`, and when measured `ubatch-size` and
   `batch-size`. The calculated context (no measurement yet) assumes q8_0.
3. **Measured.** `models.tune` (new, Dart core; the reference has no tuning routes) measures in the
   worker, for each model asked:
   - the build in use: while the `llama-server` service runs, the program and environment of its main
     process (`/proc/<MainPID>/exe` and `environ`: a wrapper script that execs the real binary counts,
     with its exports); else its ExecStart with links resolved, Environment and EnvironmentFiles, else
     `llama-server` on PATH. A wrapper script read while the service is stopped is not a build: tuning is
     refused ("start its service") and no model counts as untuned. `llama-bench` from the binary's
     folder, run with that environment; the build's kind from `--list-devices`;
   - `llama-bench -ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -b 2048 -ub 512,1024,2048 -p 2048 -n 64 -r 2 -o json`;
     the fastest prompt processing wins (a tie within 3 %: the smaller ubatch, it needs less memory);
   - the card's video memory used, sampled from sysfs (`mem_info_vram_used` of the card with the most
     video memory) before and during the winning run: fixed = peak − before − the run's own small KV;
     context = (total − before − 512 MiB − fixed) / KV bytes per token (q8_0), down to a multiple of 4096,
     at most the trained context, at least 4096;
   - refused while a local LLM holds the card (the llama-server service active with a model loaded, or
     Ollama with a model loaded): the numbers would be wrong. The answer says so; nothing is changed.
   A refusal is the task's result (`refused`, a text the app shows), not a failure.
   The result is a preview (like `models.tuning_preview`): models.ini changes with backup and Undo, plus
   the context in the configs of the agents connected to that model (as a connection writes it), applied
   with `connections.apply`.
4. **Remembered.** The measurement of each model (build path and version, kind, ubatch, prompt and
   generation speed, context, date) is kept in the app's state folder (`llm-tuning.json`, owner only).
   `models.tuning` reports `untuned`: llama.cpp models with no record, or one for another build.

## When it runs
- After a llama.cpp download finishes (started, or continued from the app's job strip): the app asks
  `models.tune` for the untuned models (the new one, plus any other not measured for this build) and
  applies the result; a message names the context and speed and offers Undo.
- When `models.tuning` reports untuned models and no local LLM holds the card: the same, for all of
  them (the build changed, or models came in another way). At start this waits 30 s for the other
  start-up tasks (the core runs four at once) and tries again a few times while the core is busy.
- On request: the Performance view gets "Measure and tune" (all models, or one).
- Connecting a model that was never measured: the calculated context (rule 1 and 2) as today's preview.

## Routes
- New `models.tune` (task; params `key`, `models` list or null for all; result a preview with `preview`,
  `models` [{name, ctx, ubatch, pp, tg, before}], `notes`). routes.json first, then `tools/protocol.py
  doc` and `client`.
- `models.tuning`: result gains `build_path` and `untuned` (list of model names).

## UI
- Performance view: "Measure and tune" per model and for all; the result card lists each model's
  context and speed before applying.
- After a download and for untuned models: in the background, then a snack bar with Undo.
- New texts in all 8 languages (appended); the manual's local LLM part says that the app measures each
  model for this card and build.

## Acceptance
- Core tests (Dart, and the reference for rule 1 and 2): `[*] ctx-size` does not stop a model from
  getting its best context; a model's own section does; the sized section carries q8_0 and flash-attn.
- Worker test with a fake `llama-bench` (JSON) and fake sysfs: the winning ubatch, the context from the
  measured memory, refused while a model is loaded, the build from a fake unit's ExecStart.
- GUI tests: Measure and tune shows the result and applies it; untuned models are tuned once in the
  background; Undo.
- On Uwe's PC (manual check): all four llama.cpp models measured on the Vulkan build, their sections
  written, pi's contextWindow updated.
- `tools/test-changed --base main` passes.
