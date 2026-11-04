# Review — Task 029: Optimal local LLM settings

Branch: `task/029-optimal-llm-settings`
Task: [docs/tasks/029-optimal-llm-settings.md](../tasks/029-optimal-llm-settings.md)

## Round 1 (Antigravity, 2026-11-04, commit dda9c2e)

### High

1. **LlamaTuner.build and LlamaTuner.measure do not resolve symlinks or wrapper scripts on
`ExecStart`/`PATH`, so `llama-bench` is not found on Maprisma installs, reconnected installs, or
wrapper-based services.**
   - llama_tune.dart:144-159, 180-185, 239-244:
     ```dart
     if (line.startsWith('ExecStart=')) {
       binary = RegExp(r'path=([^ ;]+)').firstMatch(line)?.group(1) ?? '';
     }
     ...
     if (binary.isEmpty) {
       binary = whichIn('llama-server', environment['PATH']) ?? '';
     }
     ...
     final bench = p.join(p.dirname(built.binary), 'llama-bench');
     if (!File(bench).existsSync()) {
       throw const FormatException(
         'llama-bench is not next to the llama.cpp the service runs',
       );
     }
     ```
   - **What goes wrong and when:**
     1. When Maprisma installs `llama.cpp` (LlamaCppInstaller.switchTo and unitText), it creates only the
     symlink `~/.local/bin/llama-server -> $folder/current/llama-server` (not `~/.local/bin/llama-bench`)
     and writes `ExecStart="/home/<user>/.local/bin/llama-server" ...`. Because `built.binary` is not
     canonicalized (`resolveSymbolicLinksSync`), `p.dirname(built.binary)` is `/home/<user>/.local/bin`,
     where `llama-bench` does not exist (`llama-bench` is in the build folder next to the real
     `llama-server` binary).
     2. When an existing `llama.cpp` is reconnected (ExistingAi.reconnectPlan, _llamaUnit,
     provider_llamacpp.py:144-166) or launched through a `~/.local/bin/llama-server` shell wrapper (such
     as on this machine, where `~/.local/bin/llama-server` exports `ROCM_PATH`/`LD_LIBRARY_PATH` and
     `exec`s `/mnt/Data/Ai/llama.cpp-rocm/current/llama-server`), `ExecStart` points to
     `/home/<user>/.local/bin/llama-server`. `p.dirname(built.binary)` is again `/home/<user>/.local/bin`
     (no `llama-bench`), and `built.environment` misses any `export` lines inside the wrapper script.
     3. Consequently, `models.tune` always fails with `llama-bench is not next to the llama.cpp the
     service runs` on Maprisma installs, reconnected installs, and wrapper-script services, and
     `models.tuning` (plan_worker.dart:633) reports `build_path: "/home/<user>/.local/bin/llama-server"`
     instead of the actual build binary path.

   > Author: fixed. `LlamaTuner.build` now reads the running service's main process
   > (`/proc/<MainPID>/exe` + `environ`), so a wrapper that execs the real binary gives the real build and its
   > exports (on Uwe's PC: `~/.local/bin/llama-server` → `/mnt/Data/Ai/llama.cpp-rocm/current/llama-server`
   > with the ROCm environment); otherwise ExecStart/PATH with links resolved. A script read while the
   > service is stopped is marked `script`: `models.tune` refuses ("start its service") and `untuned` is
   > empty, so the background tuning does not loop. Tests: link in ExecStart, wrapper stopped and running.

2. **Refusal when a local LLM holds the card (and any other LlamaTuner.measure `FormatException`) is
swallowed by plan_worker.dart:1479-1482 and CoreTasks, so the answer never says why.**
   - llama_tune.dart:245-250:
     ```dart
     final holder = await busy(address);
     if (holder.isNotEmpty) {
       throw FormatException(
         'The card is in use ($holder); tune when it is idle',
       );
     }
     ```
   - plan_worker.dart:1479-1482:
     ```dart
     } catch (_) {
       send({'type': 'error', 'code': 'operation_failed'});
       return 0;
     }
     ```
   - core_tasks.dart:173-179:
     ```dart
     } else if (message['type'] == 'result' && message['result'] is Map) {
       final result = Map<String, dynamic>.from(message['result'] as Map);
       task.result = task.finalize == null ? result : task.finalize!(result);
       task.state = 'done';
     } else {
       task.state = 'failed';
     }
     ```
   - **What goes wrong and when:**
     - Rule 3 (029-optimal-llm-settings.md:43-44) requires: *"refused while a local LLM holds the card
     (the llama-server service active with a model loaded, or Ollama with a model loaded): the numbers
     would be wrong. The answer says so; nothing is changed."*
     - When `LlamaTuner.measure` throws `FormatException('The card is in use ($holder); tune when it is
     idle')` inside the worker (plan_worker.dart:663-672), `runPlanWorker`'s `catch (_)` discards the
     message and emits only `{'type': 'error', 'code': 'operation_failed'}`. `CoreTasks._message` marks
     the task `'failed'` with an empty `result`, and TaskProgress._run returns `{'ok': false}`, showing
     only the generic `'The action could not be completed.'` instead of telling the user that the card is
     in use.
     - In addition, LlamaTuner.busy runs `final models = (jsonDecode(ollama) as Map?)?['models'];`
     outside a `try`/`catch`: if anything on port 11434 returns non-JSON, `jsonDecode` throws
     `FormatException` and aborts `measure()`.

   > Author: fixed. The worker turns a `FormatException` of `measure` into the result `{refused: text}`;
   > the core's preview passes it on with nothing changed or recorded; the app shows it (snack bar
   > `tune-refused`, translated in 8 languages). The texts are whole sentences now. The Ollama answer is
   > parsed in a `try`: anything else on port 11434 no longer stops the measurement. Tests in core and GUI.

### Medium

3. **Rule 4 (`llm-tuning.json`, owner-only) is not implemented; storing only a `; maprisma tuned:` line
in `models.ini` for measured rows leaves skipped/non-LLM/unfit models permanently in `untuned` and
collides across `current/` build paths.**
   - llama_tune.dart:41-47:
     ```dart
     String get mark => [
       kind,
       if (version.isNotEmpty) version,
       p.basename(p.dirname(binary)),
     ].join(' ');
     ```
   - core.dart:2240-2243:
     ```dart
     var ini = before;
     for (final m in rows) {
       ini = tunedIniText(ini, m, '${measured['mark']}');
     }
     ```
   - plan_worker.dart:634-636:
     ```dart
     facts['untuned'] = built == null
         ? <String>[]
         : untunedModels(ini, rt.models, built.mark);
     ```
   - **What goes wrong and when:**
     1. Rule 4 (029-optimal-llm-settings.md:48-50) and Acceptance (line 96) require: *"The measurement of
     each model (build path and version, kind, ubatch, prompt and generation speed, context, date) is
     kept in the app's state folder (`llm-tuning.json`, owner only). `models.tuning` reports `untuned`:
     llama.cpp models with no record, or one for another build."* No `llm-tuning.json` file is read or
     written anywhere.
     2. Because `; maprisma tuned:` is written into `models.ini` only for `rows` (`core.dart:2241`), any
     entry in `rt.models` that goes into `skipped` — such as speech/tokenizer GGUFs (`perToken <= 0`,
     skipped by `LlmTuning.collect` at llm_tuning.dart:364 with `if (!known) continue;` but still present
     in `rt.models` passed to `untunedModels` at `plan_worker.dart:636`), preset sections in `models.ini`
     whose `.gguf` file is not in `rt.modelsDir`, or models that do not fit on the card — never gets
     recorded. `models.tuning` therefore reports those models in `untuned` on every app start and after
     every download, so `_tuneUntuned()` re-runs `llama-bench` on every app launch.
     3. `LlamaBuild.mark` records `p.basename(p.dirname(binary))` rather than the build path. For builds
     under `.../current/llama-server` or `~/.local/bin/llama-server`, `p.basename(p.dirname(binary))` is
     `'current'` or `'bin'`, so switching between two builds that share `kind` and `version` (or have
     empty `version`) has the same `mark` and is not detected as a different build.

   > Author: 1 and 2 fixed: the record is `llm-tuning.json` in the state folder (owner only, atomic
   > write), written by the core when a measurement comes back, with measured AND skipped models per build
   > mark; `untuned` reads it. The models.ini marker is gone, so Undo no longer makes a model "untuned"
   > again either. 3 does not hold: `LlamaBuild.mark` already uses the binary's real folder
   > (`resolveSymbolicLinksSync`, llama_tune.dart:34-42 at dda9c2e) — the quoted `p.basename(...)` is not
   > in the code; with the binary from the running process the mark is the build's real folder anyway.

4. **`models.tuning` still reads `build` and `devices` from `llama-server` on `PATH` without the service
environment, and still calculates `best` ("fits …") and `Set to …` using `f16` instead of `q8_0` +
`flash-attn`.**
   - plan_worker.dart:620-637:
     ```dart
     if (rt.key == 'llamacpp') {
       final built = await LlamaTuner(
         home: identity.home,
         environment: identity.environment,
       ).build();
       final ini = ContextReader(
         home: identity.home,
         environment: identity.environment,
       ).modelsIniText();
       facts['build_path'] = built?.binary ?? '';
       facts['untuned'] = built == null
           ? <String>[]
           : untunedModels(ini, rt.models, built.mark);
     }
     ```
   - llm_tuning.dart:220-233, 289-292:
     ```dart
     List<Change> contextChanges(String key, String model, int ctx) {
       ...
       return [
         Change(
           context.modelsIni,
           before,
           ContextReader.iniText(before, model, 'ctx-size', '$ctx'),
         ),
       ];
     }
     ...
     if (rt.key == 'llamacpp') {
       final (now, cache) = context.llamaSettings(name);
       return (now, cache, context.llamaModelFile(folder, name));
     }
     ```
   - **What goes wrong and when:**
     1. In 029-optimal-llm-settings.md:22-25, the task notes that LlmTuning.llamaDevices runs
     `llama-server` on `PATH` without the service unit's `ExecStart` and `Environment=`
     (`LD_LIBRARY_PATH`). `LlmTuning.collect` (llm_tuning.dart:319) still calls `llamaDevices(path)`, and
     `plan_worker.dart:620-637` never propagates `built.kind` / `built.devices` into `facts['build']` or
     `facts['stacks']`. When the service binary is not on `PATH` or needs the unit's `LD_LIBRARY_PATH`,
     `facts['build']` is `'unknown'` even though `LlamaTuner.build()` succeeded.
     2. Rule 2 (029-optimal-llm-settings.md:29-31) requires: *"A model the app sizes gets, in its own
     section: `ctx-size`, `cache-type-k = q8_0`, `cache-type-v = q8_0`, `flash-attn = on`... The
     calculated context (no measurement yet) assumes q8_0."* In `LlmTuning._contextNow`
     (`llm_tuning.dart:290`), `context.llamaSettings(name)` returns `'f16'` for an unsized model
     (context.dart:332), so LlmTuning.collect computes `per_token` and `best` ("fits …") for `f16`
     instead of `q8_0` (halving the calculated context before measurement). And clicking **Set to …**
     calls `LlmTuning.contextChanges` (`llm_tuning.dart:229`), which still calls
     `ContextReader.iniText(before, model, 'ctx-size', '$ctx')` instead of
     `ContextReader.llamaSizedText(before, model, ctx)`, leaving out `cache-type-k = q8_0`, `cache-type-v
     = q8_0`, and `flash-attn = on`.

   > Author: fixed. `models.tuning` gets the build from `LlamaTuner.build()` (kind and device lines) and
   > passes it to `LlmTuning.collect`, so `build`/`devices` are the service's. "Set to …" now uses
   > `llamaSizedText` (q8_0 + flash attention where nothing is set) and the fit is computed for the cache
   > it writes (`llamaAutoCache`); the same in the Python reference (`provider_llamacpp`). Tests on both
   > sides.

5. **LlamaTuner._one ignores the exit status of the memory `llama-bench` run and uses `before` VRAM
sampled before the speed run.**
   - llama_tune.dart:299, 355-372:
     ```dart
     final card = vram();
     if (card == null) return {'name': name, 'reason': 'no graphics card found'};
     ...
     // Memory: one short run with the winner, the card's use sampled.
     final before = card.$2;
     var peak = before;
     final timer = Timer.periodic(sample, (_) {
       final now = vram();
       if (now != null && now.$2 > peak) peak = now.$2;
     });
     try {
       await run(
         argv([winner], tuneMemGen, 1),
         built.environment,
         const Duration(minutes: 5),
       );
     } finally {
       timer.cancel();
     }
     final now = vram();
     if (now != null && now.$2 > peak) peak = now.$2;
     final used = peak - before;
     ```
   - **What goes wrong and when:**
     1. Unlike the speed run (`final (speedText, done) = await run(...); if (!done) return ...` at lines
     328–333), the memory run at lines 362–366 ignores the `(_, done)` tuple returned by `run(...)`. If
     the memory `llama-bench` run crashes, fails with OOM, or times out after partially allocating
     weights in VRAM, `peak - before` is still positive (`used > 0`), and `_one` computes an oversized
     `ctx` from the partial memory reading instead of skipping the model.
     2. `final before = card.$2;` reuses the VRAM reading taken at line 299 before the (up to 10-minute)
     speed run rather than sampling `vram()` immediately before the memory run as specified in Rule 3
     (*"sampled from sysfs (`mem_info_vram_used` of the card with the most video memory) before and
     during the winning run"*).

   > Author: fixed. `before` is sampled right before the memory run, and a memory run that does not finish
   > skips the model ("llama-bench did not finish"). Test with a failing memory run.

6. **Downloads completed from the job strip (_continueJob) never trigger tuning, and _providerOperation
tunes all untuned models instead of only the downloaded model.**
   - main.dart:2546-2554:
     ```dart
     final started = await _client.jobsContinue(id: job['id']);
     if (!mounted) return;
     await _runTask(
       operation: job['kind'] == 'pull' ? 'models.pull' : 'models.download',
       existingTask: started['task'] as String,
       title: '${job['title']}',
     );
     await _refresh();
     ```
   - main.dart:3275-3292:
     ```dart
     // A new llama.cpp model is measured for this card (task 029).
     if (result != null &&
         operation == 'models.download' &&
         params['key'] == 'llamacpp') {
       _tuneAfterBusy = true;
     }
     return result;
   } finally {
     ...
     if (_tuneAfterBusy && mounted) {
       _tuneAfterBusy = false;
       unawaited(_tuneUntuned());
     }
   }
     ```
   - **What goes wrong and when:**
     - "When it runs" (029-optimal-llm-settings.md:53-54) specifies: *"After a llama.cpp download
     finishes (the app's job strip): the app asks `models.tune` for that model and applies the result; a
     message names the context and speed and offers Undo."*
     - Resuming/finishing a `llama.cpp` download from the job strip via `_continueJob` calls `_runTask`
     directly and never triggers tuning when the download completes.
     - When a download finishes via `_providerOperation`, it calls `_tuneUntuned()`, which passes no
     `model:` to `models.tune` and benchmarks every untuned model instead of just the downloaded model.

   > Author: fixed: a download continued from the job strip triggers the background tuning too (test).
   > Tuning "all untuned models" instead of only the new one stays on purpose: with the record, untuned is
   > normally just the new model, and others are only listed when they were never measured for this build
   > (which "When it runs" does next anyway). Task file updated.

### Low

7. **_tuneUntuned contends for the 4-slot CoreTasks limit on startup and does not refresh UI state after
applying `connections.apply`.**
   - core_tasks.dart:84-85:
     ```dart
     final active = items.values.where((t) => t.state == 'running').length;
     if (active >= 4) throw const FormatException('Too many active operations');
     ```
   - main.dart:4263-4270:
     ```dart
     if (firstSnapshot) {
       unawaited(_detectSetup());
       unawaited(_loadJobs());
       unawaited(_checkHealth());
       unawaited(_checkUpdates());
       unawaited(_checkMcp());
       unawaited(_tuneUntuned());
     ```
   - main.dart:3365-3370:
     ```dart
     _mapStale = true;
     var result = await _client.connectionsApply(plan: plan['plan'] as String);
     if (result['task'] is String) {
       result = await _awaitTask('connections.apply', result);
     }
     _connectionUndo = result['undo'] as String?;
     ```
   - **What goes wrong and when:**
     1. On `firstSnapshot`, `_detectSetup`, `_checkHealth`, `_checkUpdates`, `_checkMcp`, `_tuneUntuned`,
     `_quietAddonCatalog`, `_lookForNewApps`, and `_loadGpu` are all launched concurrently without
     awaiting. Because `CoreTasks._slot` allows at most 4 running worker tasks, `_tuneUntuned()`'s
     `models.tuning` call (or the startup calls right after it) fails with `Too many active operations`.
     2. When `_tuneUntuned()` finishes applying a tuning plan (`main.dart:3365-3370`), it mutates
     `_mapStale` and `_connectionUndo` without calling `setState` or `_refresh()`, so open views do not
     update until another event rebuilds the widget tree.
   > Author: fixed. At start the background tuning waits 30 s for the other start-up tasks and tries again
   > (up to 5 times) while the core is busy; after the apply it sets the state with `setState` and refreshes
   > the views like the normal apply. GUI test with one refused `models.tuning` and the refresh (fails
   > without the fix).

## Round 2 (Antigravity, 2026-11-04, commit 4d8d0e7)

All 7 findings of round 1 checked as fixed; finding 3 point 3's answer confirmed (`LlamaBuild.mark`
already resolved links at dda9c2e). No new findings.

CLEAN

> Author: Antigravity's own worktree was still at dda9c2e; it read the fixes in
> /mnt/Data/Projects/maprisma-claude, which was clean at 4d8d0e7 (its line references match that commit:
> main.dart:4313, 3411-3412, plan_worker.dart:678-681), so the round covers 4d8d0e7.
