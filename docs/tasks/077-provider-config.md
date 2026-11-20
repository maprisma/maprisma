# 077 Configure each local provider for this PC

Author: Codex · Reviewer: Antigravity · Branch: task/077-provider-config
(started from `task/078-unified-ask-ai` / `main` after 078). Plan review
rounds 1–3 are in [reviews/077-provider-config.md](../reviews/077-provider-config.md),
and all findings plus the 078 alignment are taken in below (v5).

## Goal

Every local LLM provider gets a **"Configure for this PC"** action. Maprisma
works out the best settings for this PC's hardware (graphics card, video
memory, RAM, CPU, ROCm/Vulkan/CUDA/CPU), so models run fast with the largest
context that fits. The user sees why each value was chosen, can change the
important parameters by hand with checks that catch mistakes, and Ask AI can
propose a complete configuration that is applied with one review.

## Decisions (Uwe, 2026-11-19)

- **Local providers only:** llama.cpp, Ollama, LM Studio, Jan, KoboldCpp,
  vLLM and Strata. Online providers are out of scope. Add-on providers
  can't bring writers yet (they get nothing in 077), which is noted as an
  open point.
- The configuration is an **action per provider**: on the map box (and its
  menu), on the Providers page and in Ask AI.
- Important parameters can be **changed by hand**. Everything is applied as
  a preview with backup and Undo.
- **Codex builds it, Antigravity reviews it.**

## What exists (inventory 2026-11-19, main)

- **Engine facts:**
  - They come from the Python engine classes (`Engine.tuning`,
    `llm_engine.py:293-310`). `tools/adapter-assets.py:23` exports a fixed
    list of engine keys into `adapter_assets.g.dart`, and Dart reads them
    through `llm_tuning.dart` (`engineFacts`, `tuningKeys`).
  - Tunable today: llama.cpp (8 keys, per model, `models.ini`) and Ollama
    (4 global `OLLAMA_*` keys in `~/.config/ollama/server.env`, only when the
    app installed it).
- **Context writers** in `context.dart`, used when connecting an agent:
  - LM Studio: `<ident>.json`, nested `{checked, value}` for the KV keys;
  - Jan: `model.yml` `ctx_size` **and** `router.preset.ini`; the headless
    service reads only the preset;
  - KoboldCpp: `.kcpps` `contextsize`.
- **vLLM** is a `RefusedInstaller` (no Dart installer). It serves
  safetensors, not GGUF.
- **Strata** presets may contain API keys (`strata.dart:117`).
- **The llama.cpp unit** (`installers.dart:1050`) hard-codes
  `--gpu-layers all --flash-attn on` on `ExecStart`, so these flags win
  over `models.ini`.
- **Routes:**
  - `tuningRoute` (`core.dart:2442`) refuses every provider without tuning
    keys. `models.tuning` caches its facts (`tuningFacts`, 10 min).
    `models.tune` measures llama.cpp (029) and stores `{mark, ctx, ubatch,
    pp, tg}` or `{mark, reason}` at parallel 1 in `llm-tuning.json`.
  - `_dispatch` is synchronous. `_invalidRequest` (`core.dart:5523-5531`)
    returns bare `invalid_request` except for an allowlist of localized
    messages (including `'This proposal has expired'` and `'This helper is
    not ready'`).
- **Memory sizing:** `context.dart` uses a 1.5 GiB reserve, a `fixed` KV term
  for sliding-window layers, and one cache type for K and V.
  `health_report.dart` reads only `MemTotal` and logical cores. `readGguf`
  doesn't read `general.file_type`.
- **Ask AI (078 unified Ask AI):**
  - Central Ask AI (`map_smart_card.dart:1175-1183, 2503-2660`) uses a single
    composer (`_unifiedComposer`, `MicButton` + `_voiceNotice`), sends
    `map.smart_ask` with `column: "auto"` and optional bounded `context`
    (≤ 3,000 chars) for follow-ups (`_responseField`, `2671-2761`), and
    supports `status: "answer"` with optional HTTPS `sources`.
  - `smartRoute` (`core.dart:3399-3413`) builds `'providers'` for
    `auto || column == 'providers'`, with `'performance': rt['installed'] == true`
    (the page fails for 5 providers).
  - `smartAsk` (`smart_card.dart:2240-2292`) calls `smartAutoPrompt`
    (`smart_card.dart:2131-2152`) first in `auto` mode, passes `decision` to
    `smartProviders` (`smart_card.dart:1084`), emits progress stages
    (`plan_worker.dart:1337-1340`), and finalizes through `finalizeSmartAsk`
    (`core.dart:4585-4586`: `_dropRefused` → `smartWorded` → `smartProposals.keep`).
  - `smartCandidateChecks` (`smart_card.dart:135-183`) returns `const []`
    when `candidate['action']` is not a `Map`, and returns no checks for
    `performance` (`smart_card.dart:170`).
  - The rule is "one click, at most two answers, never a retry"
    (`smart_card.dart:30-31`).
  - Permissions come from `settings.json['action_rules']` (`action_rules.dart`);
    `_rulesForHelper('auto')` (`core.dart:4554-4561`) passes all categories.
- **GUI:**
  - `performance_view.dart` shows number keys read-only and has no
    per-model editing. Inside Ask AI, Performance opens embedded via
    `performancePage` (`main.dart:1894-1925`, `map_smart_card.dart:948-1005,
    3867-3882`), gated on `runtime['tunable'] == true`.
  - `ConnectionReview` (`connections_view.dart:510-519, 601-608`) has `busy`
    handling (keep it), but no warning tick and no restart option.
  - `ProviderOps` has no restart, and `connections.apply` never runs
    `daemon-reload`.

## Design

### 1. Config schema (engine facts)

- **Where it lives:** add `config` to the engine classes, and add `config`
  to the exported keys in `tools/adapter-assets.py:23`. `tuning` stays for
  compatibility.
- **Fields of each key:**
  - `id` and `label`;
  - `type`: `int`, `float`, `enum`, `bool` or `int_or_special` (with
    `special`, for example `["all"]` or `[-1]`);
  - `range` or `values`, and `unit`;
  - `wire`: how it is written, for example `"on"|"off"|"auto"`, `"0"|"1"`,
    `{checked, value}`, or integer enum `0|1|2`;
  - `scope`: `global`, `default` (a shared defaults section) or `per_model`;
  - `importance`: `main` or `advanced`;
  - `writer`: an opaque id;
  - `restart`: `service`, `model_reload` or `none`;
  - `verified`: from step 0;
  - `help`.

| Provider | Main keys | Advanced | Writer | Writable when |
| --- | --- | --- | --- | --- |
| llama.cpp | ctx-size (total, shared across slots), gpu-layers (`all` or 0..blocks+1), cache-type-k, cache-type-v, flash-attn (`on`/`off`/`auto`), parallel | batch-size, ubatch-size, threads | `models.ini` (`*` = default, plus model sections). If a Maprisma-owned unit hard-codes `--gpu-layers` or `--flash-attn`, those flags are removed from `ExecStart` in the same plan (with `daemon-reload`). A foreign unit or script gives a warning: "the unit's flags win" | `models.ini` is writable for every installed llama.cpp (it may be created). A foreign unit or script only adds the warning. Editing `ExecStart` needs Maprisma's own unit |
| Ollama | OLLAMA_CONTEXT_LENGTH (**per slot**), OLLAMA_KV_CACHE_TYPE (one type for K and V), OLLAMA_FLASH_ATTENTION, OLLAMA_NUM_PARALLEL | OLLAMA_MAX_LOADED_MODELS | `server.env` | only the app-installed `server.env` (must exist). A system Ollama (pacman) is **read-only**, with a copyable systemd drop-in snippet |
| LM Studio | contextLength, gpu offload (format from step 0), flash attention, K/V cache quantization (`{checked, value}`) | step 0 decides | `<ident>.json` per model (may be created) | per model only |
| Jan | `ctx_size`, `ngl`, flash attention, cache type (names from step 0) | threads | `model.yml` **and** `router.preset.ini` together, in one plan | per model only; existing files only |
| KoboldCpp | contextsize, gpulayers (`-1` = auto, or 0..N), flashattention, quantkv (`0|1|2`) | threads, blasbatchsize | existing `.kcpps` | per model only; `restart: model_reload` |
| vLLM | max-model-len, gpu-memory-utilization (float 0.50–0.95), max-num-seqs, kv-cache-dtype (`auto`/`fp8`) | tensor-parallel-size (≤ GPU count) | none in 077 | **advice only:** a copyable `vllm serve` command line. Sized from the HF `config.json` when it is readable; otherwise hardware only |
| Strata | step 0 decides, from an allowlist of non-secret fields only | — | none in 077 | **advice only.** The preset file is never read beyond allowlisted fields, never diffed and never sent to Ask AI |

**Step 0** (before any writer): check every provider installed on this PC
read-only, and record the real file formats and key names in this file:
- LM Studio: its version and per-model JSON keys, gpu offload included;
- Jan: the `model.yml` and `router.preset.ini` keys;
- KoboldCpp: the `.kcpps` keys;
- llama.cpp: whether its unit flags exist and whether the unit is
  Maprisma's own;
- Ollama: whether it was installed by the app or by the system;
- vLLM and Strata: how they are started.

A key that is not verified is not written (`verified: false` shows it
greyed out with "not verified on this PC"). Providers that aren't installed
get fixtures from the documented formats.

#### Step 0 findings (Codex, 2026-11-19)

Read-only checks of PATH, application directories, package names, desktop
entries, file ownership, unit text and the installed binaries' `--help`:

| Provider | This PC | Verified format / startup |
| --- | --- | --- |
| llama.cpp | Installed, running; Vulkan `b12078` via the user's shell wrapper; ROCm `b11895` also on disk | `~/.config/llama.cpp/models.ini`, version 1, `[*]` and model sections. Installed help verifies `ctx-size`, `gpu-layers` (`all` or integer), `cache-type-k/v` (`f16`, `q8_0`, `q4_0`), `flash-attn` (`on/off/auto`), `parallel`, `batch-size`, `ubatch-size`, `threads`. The user unit is uid 1000, mode 0644, marked **installed by AI Agents Map** (recognized ownership marker), and has both `--gpu-layers all` and `--flash-attn on`. `models.ini` is uid 1000, 0600. The wrapper is user-owned and must stay untouched. |
| Ollama | Installed, running; app-managed `v0.40.11`, no system Ollama package | `~/.local/bin/ollama` resolves into `/mnt/Data/Ai/ollama/v0.40.11`; its install marker exists. User unit marked **installed by AI Agents Map**, `ollama serve`, existing `~/.config/ollama/server.env` uid 1000, 0600. Installed `serve --help` verifies all five `OLLAMA_*` schema names. Environment wire values are strings; cache is `f16/q8_0/q4_0`, flash is `0/1`. |
| LM Studio | Not installed (no app, CLI, root or desktop entry) | Documented fixture only: concrete defaults JSON `load.fields[{key,value}]`; `llm.load.contextLength`, `llm.load.llama.acceleration.offloadRatio` is a **fraction 0..1**, with `max/off` aliases, not a layer count. Flash is boolean. `kCacheQuantizationType` and `vCacheQuantizationType` are `{checked,value}`. Thread key is `llm.load.llama.cpuThreadPoolSize`. Verified in the [official schema](https://github.com/lmstudio-ai/lmstudio-js/blob/main/packages/lms-kv-config/src/schema.ts) and [value types](https://github.com/lmstudio-ai/lmstudio-js/blob/main/packages/lms-kv-config/src/valueTypes.ts). |
| Jan | Not installed (no app, CLI, data root or desktop entry) | Documented fixture only: YAML `ctx_size`, **`n_gpu_layers`** (the UI calls it `ngl`), `flash_attn`, `cache_type_k/v`, `parallel`, `threads`; preset equivalents `ctx-size`, `n-gpu-layers`, `flash-attn`, `cache-type-k/v`, `parallel`, `threads`. Both existing files are changed together. This corrects the draft's YAML `ngl` spelling; see the [official mapping](https://github.com/janhq/jan/blob/main/extensions/llamacpp-extension/src/index.ts) and [preset generator](https://github.com/janhq/jan/blob/main/extensions/llamacpp-extension/src/preset.ts). |
| KoboldCpp | Not installed (no binary, config root or desktop entry) | Documented fixture only: existing JSON `.kcpps`; `contextsize`, `gpulayers` (`-1` auto), `flashattention` boolean, `quantkv` legacy integers `0/1/2` (f16/q8/q4), `threads`, `blasbatchsize`. Upstream accepts those legacy spellings and values; newer files also have `noflashattention` and `batchsize`, which must be kept consistent when present. See [official source](https://github.com/LostRuins/koboldcpp/blob/concedo/koboldcpp.py). Reload is the admin reload-config API, never a service restart. |
| vLLM | Not installed (no binary, environment root or unit) | Advice only. `vllm serve MODEL` arguments verified against [official engine arguments](https://docs.vllm.ai/en/latest/configuration/engine_args/): `max-model-len`, `gpu-memory-utilization`, `max-num-seqs`, `kv-cache-dtype`, `tensor-parallel-size`. No writable unit is assumed. |
| Strata | Not installed (no CLI, terminal root, presets root or unit) | Advice only: Maprisma's verified integration starts its own terminal CLI with `launch --preset NAME --no-tui` and stops with `launch --stop`; the server is `-m serve.server`. No preset was read. No tuning key is verified, so configuration advice directs the user to `strata launch`; no guessed preset setting is written or sent to AI. |

For absent providers, tests use the verified upstream formats above, not an
assertion that these applications were exercised on this PC. Unknown keys
remain disabled. Strata has no verified editable settings in this round.
Neither running service was started, stopped, loaded, unloaded or changed.

### 2. Hardware facts (`pc_facts.dart`, Linux)

- **VRAM:** total per card, from sysfs or `nvidia-smi`. The free baseline
  is `vram_total − other_used`, where `other_used` is the VRAM not held by
  this provider. Per process from `GpuUsage`/`procVram` on amdgpu. On
  NVIDIA and others `other_used = 0` (so `avail = vram_total`), and the
  single `reserve` in `need` is the only deduction, never subtracted
  twice.
- **RAM** from `MemAvailable` (not `MemFree`) plus `MemTotal`.
- **CPU:** physical cores from `/sys/devices/system/cpu/cpu*/topology`
  (unique package and core ids), with logical cores as a fallback.
- **GPU count** for vLLM's tensor-parallel-size.
- **Stack and build:** `stacksHere`, `llamaDevices`, `LlamaBuild`.
- **Per model:** `readGguf` gains `general.file_type` (the quantization).
  The model list is capped at 40 per provider, like `llm_tuning.dart:352`.

### 3. Recommender (`provider_config.dart`, deterministic, no AI)

- **Profiles:** Balanced (default), Long context, Fast, Several agents.
  Each profile has a target minimum context: 8192, 32768, 8192 and 8192 per
  slot.
- **Memory model** (it reuses `context.dart`'s `kvLayout`, extended to take
  `cacheK` and `cacheV` separately; the `fixed` term is always included):
  - `kv(ctx) = fixed + ctx × kv_per_token(cacheK, cacheV)`
  - `need = weights_on_gpu + kv_on_gpu + reserve` for GPU fitting; CPU-only
    fitting uses the full weights and `kv_total`. With full offload,
    `kv_on_gpu = kv_total`. For a verified llama.cpp b12078 build
    (`ini_defaults`, matching version and a nonempty build mark), partial
    offload includes the output layer first: `gpu-layers = 1` has no GPU
    KV, and the last `max(0, gpu-layers − 1)` repeating layers supply the
    GPU KV. Sum those layers' actual metadata, including heterogeneous KV
    heads and sliding-window fixed terms; do not scale the full cache by
    an average fraction (verified against b12078's
    [layer placement](https://github.com/ggml-org/llama.cpp/blob/b12078/src/llama-model.cpp)
    and [KV allocation](https://github.com/ggml-org/llama.cpp/blob/b12078/src/llama-kv-cache.cpp)).
    For other partial-offload builds, display full
    KV as an explicitly labelled upper bound rather than claiming its
    GPU residency is known. This assumes normal KV offload, without
    foreign tensor-placement or no-KV-offload flags.
  - `reserve` is 1.5 GiB, as
    in `context.dart`. With a valid llama.cpp record, the reserve is computed
    in `LlamaTuner._one()` (`llama_tune.dart`), where `weights`, `meta`,
    `cacheK`, `cacheV` and `used` are all known. `used` is the peak at the
    bench's `tunePrompt + tuneMemGen` tokens, not at `record.ctx`:
    - `overhead = max(0, used − weights − kv(tunePrompt + tuneMemGen,
      cacheK, cacheV))`
    - `reserve = overhead + tuneMargin`

    This gives exactly `llama_tune.dart:463` again when recalculated at the
    measured profile. `_one()` returns `reserve`, `cache_k` and `cache_v`,
    and `withMeasurement` stores `{used, reserve, cache_k, cache_v}`. Old
    records without `reserve` use 1.5 GiB and assume q8_0.
  - **Slots:**
    - llama.cpp and Jan: `ctx-size` is the total and is split across
      `parallel` slots, so `kv_total = kv(ctx)`, and the per-slot context
      is `ctx / parallel`.
    - Ollama: `OLLAMA_CONTEXT_LENGTH` is per slot, so
      `kv_total = parallel × kv(ctx)`.
    - With `OLLAMA_MAX_LOADED_MODELS = m`, the fit sums the `m` largest
      installed chat models.
  - Ollama's global context is sized against the largest installed chat
    model. With none installed, it stays conservative at 8192 with a note.
- **Order** (this breaks the offload/context cycle):
  1. Try a full offload at the profile's target context.
  2. If that doesn't fit, only engines with a `gpu_layers` or `gpu_ratio`
     key, or Ollama's per-slot runtime, may use partial offload. Select the
     greatest layer count whose scaled weights, GPU KV (or its explicit
     upper bound) and single reserve fit, with a speed warning.
  3. For those offload-capable engines, weights above the available GPU
     memory can lead to CPU only (layers 0, threads = physical cores), or
     "model too large for this PC". vLLM has no offload key: it stays on
     the GPU and sizes context against
     `min(vram_available, utilization × vram_total)`. If even its weights
     and reserve cannot fit, say "Model too large for this GPU" and keep
     the recommendation invalid instead of substituting a RAM budget.
  4. Grow the context with the memory that is left, rounded down to a
     multiple of 4096. For the verified partial llama.cpp layout, also
     bound context by the CPU-resident weights and cache against available
     RAM. The reserve is included once in the selected fit basis.
  5. Clamp last: `min(trained, max(minContext, ctx))`, where minContext is
     never above trained.
- **Other keys:**
  - **KV cache:** q8_0 with flash attention where the engine and backend
    support it. q4_0 only in the Long context profile, with a quality
    warning. vLLM uses `fp8` only on supported cards, otherwise `auto`.
  - **Threads:** physical cores when part or all of the model runs on the
    CPU, otherwise the engine default.
  - **Batches:** batch 2048 and ubatch 512, or the measured winner.
  - **parallel:** 1, or 2–4 in the Several agents profile.
  - **Fractions:** round recommended utilization and `gpu_ratio` down to
    two decimal places before fitting and presenting values or snippets.
- **llama.cpp measurements:** a record counts only when `record.mark` is
  the current build's mark and `ctx` and `ubatch` are present. Skipped rows
  are ignored. When the profile's `parallel` or KV cache type differs from
  the record (parallel 1, q8_0), the context is calculated again from the
  record's `reserve` (or 1.5 GiB when the record has none).
- **Output** per key: `{id, current, recommended, reason, source:
  measured|calculated|default}`, plus
  `fit {weights, kv, reserve, total, available, basis: "vram"|"ram"}`.

### 4. Validator (shared by manual edits, the recommender and Ask AI)

- **Type, range and `special` values** from the schema.
- **Cross-key rules:**
  - ubatch ≤ batch;
  - quantized KV needs flash attention:
    - llama.cpp: when cache-type-v is quantized;
    - Ollama: when any quantized `OLLAMA_KV_CACHE_TYPE` is set;
    - KoboldCpp: when quantkv > 0;
    - LM Studio and Jan: as their keys say;
  - gpu-layers ≤ blocks + 1, or `all` / `-1`;
  - threads ≤ logical cores;
  - ctx > trained gives a warning;
  - vLLM: utilization × vram_total above the free baseline gives a
    transient-memory warning; tensor-parallel-size ≤ GPU count is a
    capacity rule. Fit itself must stay within the utilization budget.
- **Fit:**
  - An **error** when GPU-resident weights + GPU KV + the single reserve
    exceed `vram_total`, with full or verified partial offload. Partial
    offload cannot make an impossible GPU allocation loadable. For an
    unverified partial layout, weights + reserve alone above capacity is
    an error; an overflowing full-KV upper bound is a warning, since the
    unknown cache placement must not produce a false hard refusal.
  - An **error** when `need > MemTotal` on CPU only. vLLM additionally
    rejects need above `utilization × vram_total`, and never treats RAM
    as an alternative GPU capacity. Missing GPU hardware is an error for
    a GPU-only engine. These are capacity limits, not transient free
    memory.
  - Partial offload also checks the CPU-resident allocation:
    `cpuWeights = fullWeights − gpuWeights`, plus
    `cpuKv = fullKv − gpuKv` when GPU cache placement is verified. Unknown
    placement contributes zero CPU KV to this lower-bound check, avoiding
    false refusals. `cpuWeights + cpuKv > MemTotal` is an **error**; above
    `MemAvailable` is a **warning**. Keep only one available-memory warning
    when both GPU and CPU allocations exceed their free baselines. The
    reserve is already counted in the GPU basis and is not added again.
    Unknown RAM facts (`MemTotal = 0`) do not produce an availability
    warning. A known positive total with zero available RAM still warns.
  - A **warning** when `need` is above the current free baseline, or with
    partial offload (which can be slower even when it fits). Unknown GPU
    cache placement has its own upper-bound warning. A model loaded by
    this provider itself doesn't count against the free baseline.
- **Result:** `{errors[{key, text}], warnings[{key, text}], fit}`.

### 5. Routes (`routes.json` first, `source: "manual"`, Dart only)

| Route | Kind | Params | Result |
| --- | --- | --- | --- |
| `models.config` | read | `key, model?, profile?` | `{task}`. Result: `{schema[], scope_models[], current{}, recommended[], fit{}, hardware{}, models[] (≤40), helpers[], can_control, running, untuned[], focus, writable, read_only_reason?, snippet?, restart, notes[]}`; it fills the facts cache |
| `models.config_check` | read | `key, model?, values{}` (≤ 32 entries) | `{errors[], warnings[], fit{}}`; synchronous pure math against the cache; `{error: "stale"}` when there is no cache or it is older than 10 min |
| `models.config_preview` | preview | `key, model?, values{}, config_proposal?` | from the cache. Validator errors give `{ok: false, errors[], warnings[]}` and no plan. Otherwise `{ok: true, plan, warnings[], restart}`, applied with `connections.apply` |
| `models.config_ask` | read | `key, model?, profile?, command, focus?` (≤ 500 characters) | `{task}`. Result: `{config_proposal: string (handle), values{}, reasons{}, summary}` or `{error, code}` |
| `providers.restart` | change | `key` | `{task}`. The worker (like `providers.run`) runs `guardModel` (refuses while an agent is generating), then `stop` and `start` through `ProviderOps`. The route checks `action_rules` `stop` **and** `start` on `providers` |
| `providers.reload_model` | change | `key, model` | `{task}`. For `restart: model_reload`: a guarded unload, then a load where the provider can load. KoboldCpp gets `/api/admin/reload_config` (`{"filename": "unload_model"}`, `provider_koboldcpp.py:67`) in `ProviderOps.unloadModel`, instead of falling through to `stop`. Where a provider can't do it, there is no button, only a hint |
| `providers.snapshot` | read | unchanged | rows gain `configurable` (`tunable` stays) |
| `map.smart_ask` | read | unchanged (`column`, `command`, `request`, `answer?`, `context?`) | update `routes.json:1401` note to document `provider_config` candidates (`{id, kind, title, subtitle, reason, fit, size, key, model?, profile, values{}, reasons{}, writable, config_proposal}`) alongside 078's `auto`, `context`, `answer` and `sources` |

- `model` is `*` only where the schema has `scope: default` (llama.cpp).
  Per-model-only providers (LM Studio, Jan, KoboldCpp) need a concrete
  model; the default is the loaded model, otherwise the first.
- **Writers:**
  - They check with `checkTrusted(p.dirname(path))` on the **parent
    folder**, as it works today: trusted ancestor symlinks are allowed,
    owner and permissions are checked. Then `ConfigFiles.read(path)` reads
    the file (`O_NOFOLLOW` plus `uid`, so a symlinked or foreign leaf file
    is refused). Never `LlmTuning._read`.
  - **Anchor files** must exist: `server.env`, existing `.kcpps`,
    `model.yml`, `router.preset.ini`, and the llama.cpp unit, but the unit
    only for editing `ExecStart`.
  - **Override files** may be created: LM Studio `<ident>.json`,
    Maprisma's `models.ini`.
  - Unknown keys, comments and order are kept. `envWith` is fixed so
    duplicate `NAME=` lines become one. The `iniText` writer keeps inline
    comments and can remove a per-model override ("use the default").
- **Engine defaults:** an unset current value is shown as the engine default, rather than a guessed live value. For llama.cpp/Jan, a context edit requires a positive parallel count when no explicit count is known, so the app can synchronize a definite per-request context. Use recommended supplies it.
- **Agent contexts:** a preview includes agent-config changes only when
  the effective per-slot context of a model changed. `contexts` is filled
  for all of the provider's models, and Hermes keeps its `default_model`
  (it never gets `''`).
- **systemd:** `connections.apply` and `connections.undo` (`plan_worker.dart`
  `applyPlan`) run `systemctl --user daemon-reload` themselves whenever they
  write or restore a `.service` file or drop-in. `connections.undo` runs in
  `core_tasks.dart:413` (`Connections.undo` → `ConfigFiles.undo`), so both
  paths get an injectable `daemon-reload` hook, and tests assert it without
  a real `systemctl`. This covers apply, undo
  and a later restart, whether or not "Restart now" is used.
- **Registration:**
  - `actionChecks`: `models.config_preview` →
    `[ActionCheck('update', 'providers', key)]`; `providers.restart` →
    stop and start checks; `providers.reload_model` → `ActionCheck('stop', 'models', model)`
    and `ActionCheck('start', 'models', model)`, as for `model.unload` and
    `model.load` (`action_rules.dart:164`).
  - Add `restart` and `reload_model` to `CHANGE` in `tools/protocol.py:41`.
    `action_rules_test` asserts **both** the stop and start checks of the
    restart, not only `.first`.
  - `smartCandidateChecks`: `provider_config` → the same update check.
  - `action_rules_test` gets matching entries. The other route kinds come from `tools/protocol.py` `kind()` as they
    are.

### 6. Ask AI

**Additional user decision (2026-11-19):** provider configuration Ask AI,
including the action opened from a provider's Performance/Configuration
page, offers an optional **Search the web for guidance** switch. Only
helpers with a research form can use it; local helpers keep working
without web access. This replaces the no-tools requirement below only
when the switch is selected: the proposal call then uses the adapter's
read-only research form, not an extra call. Return bounded HTTPS sources
with the advice. The validator, verified-key allowlist, review and
at-most-two-calls/no-retry rule remain in force. Central Ask AI passes the
same explicit option to provider configuration; it never grants research
capability on the helper's own request.


- **Separate route (on the Configuration page):** `models.config_ask` runs
  through `smartAgent` (online helpers in the no-tools form, local helpers
  through `adviseArgv`), using `smartHelpers()`. The prompt gets the cached
  facts, the schema, the current values and the recommender's values with
  reasons (for Strata, allowlisted non-secret fields only), and the AI may
  return only schema keys. The validator runs on the answer, and an invalid
  answer gives `bad_answer`. **One call, no automatic retry.**
- **Through `map.smart_ask` (`column: "auto"` and explicit `column: "providers"`):**
  at most **two** helper calls per click, never a retry, and never `lookup`
  from the second call:
  1. **Call 1 (routing):** in `auto` mode, `smartAutoPrompt`
     (`smart_card.dart:2131-2152`) asks the helper to return
     `{"area": "providers", "action": "provider_config", "provider": "<key>", "model": "<optional>", "profile": "<balanced|long_context|fast|several_agents, optional>", "focus": "<optional>"}`
     (replacing `performance`). `smartProvidersPrompt` (`smart_card.dart:1056`)
     gets the same `provider_config` choice for explicit `column: "providers"`
     callers. In `smartAsk` (`smart_card.dart:2263-2270`), route
     `action == 'provider_config'` to `smartProviders` even when the model
     omits `"area"` (matching `addon`), normalizing `area = 'providers'`.
  2. **Validation before Call 2:** inside `smartProviders`
     (`smart_card.dart:1084`), handle `action == 'provider_config'` in its own
     branch (before the `p[action] == true` lookup), checking
     `p['configurable'] == true`, valid `profile` (if given), and valid
     `model` (if given), plus `ruleAllows` against `facts['action_rules']` for
     `ActionCheck('update', 'providers', key)` so an invalid or denied request
     never spends Call 2 tokens.
  3. **Call 2 (config proposal):** `smartAsk` (`smart_card.dart:2156-2165`)
     and `smartProviders` take an injectable config-facts collector callback
     (like `hub` and `mcpSearch`, wired in `plan_worker.dart:1329-1349`). The
     worker emits `progress?.call('Checking…')`, collects fresh hardware and
     provider config facts, runs the deterministic recommender, and makes
     **one** proposal call via `agent(...)` (which emits `'Ask AI'`), passing
     `facts['context']` (via `_request(facts)`) when present. The shared
     validator checks the answer; an invalid answer returns `status: 'error'`
     (`bad_answer`), never `redirect` and never a retry. The second call's
     non-empty `summary` is returned on the proposal (so `smart_card.dart:2314-2317`
     does not fall back to Call 1's pre-facts summary).
- **Candidate shape, `finalizeSmartAsk`, and `SmartProposals.keep`:**
  - The worker returns a full candidate:
    `{id: 'c1', kind: 'provider_config', title, subtitle, reason, fit: 'ok', size: 0, key, model?, profile, values{}, reasons{}, writable, action: {'kind': 'provider_config', 'key': key, 'model': model, 'values': values, 'facts': collectedFacts}}`.
    Including the `action` map is mandatory so `smartCandidateChecks`
    (`smart_card.dart:135-137`) runs and `_dropRefused` cannot be bypassed.
  - In `finalizeSmartAsk` (`core.dart:4585-4586`), run `_dropRefused` first;
    then, for each surviving `provider_config` candidate, store
    `action.remove('facts')` in the core facts cache (so `SmartProposals` never
    holds raw facts for 30 min and never sends them to the GUI) and mint a
    `config_proposal` handle on the candidate (separate from `SmartProposals`'
    top-level `proposal`), then run `smartWorded` and `smartProposals.keep`
    (which strips `'action'` at `smart_card.dart:2391`). Denied candidates
    never populate the cache or mint a handle, and `_dropRefused` preserves
    `helper` and `local` (`core.dart:4647-4648`).
- **`smartProviders` facts and `smartCandidateChecks`:**
  - In `smartRoute` (`core.dart:3399-3413`), replace
    `'performance': rt['installed'] == true` (`3411`) with `'configurable'`
    (true only for installed local providers with a config schema).
  - In `smartCandidateChecks` (`smart_card.dart:170`), remove the
    `performance` empty-checks case and add
    `'provider_config' => [ActionCheck('update', 'providers', '${candidate['key']}')]`.
  - In `smartStepNames` (`smart_card.dart:919`), replace `'performance'` with
    `'provider_config': 'Configure for this PC'`.
  - Update the existing 078 tests that assert `performance`:
    `packages/maprisma_core/test/smart_card_test.dart:1016, 1093` and
    `flutter_app/test/smart_window_test.dart:605-690`.
- **Review handoff and embedded Configuration page (`map_smart_card.dart` & `main.dart`):**
  - In `_buildProposal` (`map_smart_card.dart:3495-3543`), handle
    `c['kind'] == 'provider_config'` explicitly (never fall through to
    `_openReview` / `map.smart_review`). Use auto-mode effect labels:
    `'Review configuration'` when `c['writable'] == true`, `'Open Configuration'`
    when advice-only (replacing `'Open Performance'` at `3532-3533`).
  - Extend `performancePage` (`map_smart_card.dart:582-587, 948-1005`,
    `main.dart:1894-1925`) to accept optional prefill
    `{model?, profile?, values{}, reasons{}, config_proposal}`, check
    `runtime['configurable'] == true`, load `models.config`, and open the
    Configuration page inside the Ask AI overlay prefilled with the proposal
    (advice-only providers show their snippet there). Update `_smartProvider`
    (`main.dart:2400-2408`) for the non-embedded fallback.
  - In `_aside` (`map_smart_card.dart:985-997`), reload fresh (dropping
    prefill) only after an applied change; cancelling the review returns to
    the Configuration page with the prefilled/edited values preserved.
- **Follow-ups (`_responseField`, `map_smart_card.dart:2671-2761, 3915-3919`):**
  - In `_responseField`'s `evidence` builder (`map_smart_card.dart:2681-2691`),
    include a compact summary of a `provider_config` candidate's `key`,
    `model`, `profile` and `values{}` (bounded within 3,000 chars), and
    **never** include `config_proposal`, file paths or secrets in
    `_previousContext`.
  - An explanation follow-up (e.g. "Why 16k context?") is answered by Call 1
    with `{"action": "answer", "summary": "..."}` in **1 call**; a refinement
    follow-up (e.g. "Use q4_0 instead") runs Call 2 against freshly collected
    facts and mints a new `config_proposal`. Helper-switch consent
    (`map_smart_card.dart:2704-2715`) works automatically via `helper`/`local`.
- **Provenance:** `config_proposal` is a core handle (random, in memory,
  30 min expiry) bound to `{key, model, values}`.
  - `models.config_preview` with a proposal checks that `values` match the
    binding exactly.
  - As soon as the user changes **any** value, the GUI drops the proposal
    and the whole preview becomes manual.
  - An unknown or expired proposal is refused with
    `FormatException('This proposal has expired')`, which `_invalidRequest`
    (`core.dart:5523-5531`) already forwards localized to the GUI.
  - Permissions are the same in both cases: `actionChecks('models.config_preview')`
    and `smartCandidateChecks('provider_config')`. There is no separate
    rule for "an AI step".
- **Examples:** "Configure Ollama for long context", "Make llama.cpp as fast
  as possible", "Set up LM Studio for two agents at once", and 078's existing
  starter example "Why are answers slow on this PC?" (`map_smart_card.dart:2596`).

### 7. UI

- **"Configure for this PC"** (only for configurable providers):
  - the map box's speed icon (`main.dart:4321-4330`, gated by `_tunable` at
    `main.dart:2516-2526` switched to `configurable`) becomes the Configure
    action, also in the box menu (`_addonMenu`);
  - the Providers page (`providers_view.dart:169`);
  - Ask AI's `provider_config` proposals (opened embedded inside Ask AI via
    `performancePage`, `main.dart:1894-1925`).

  It opens the Performance page, renamed **"Configuration"**.
- **Top: hardware strip and profile chips.**
- **Model picker:**
  - llama.cpp: "All models (default)" plus each model;
  - other per-model providers: models only;
  - Ollama: none (global).
- **Main table:**
  - columns: current | recommended (the reason as a tooltip, a
    measured/calculated icon) | **your value**;
  - your value is a number field with a stepper, a float field, a
    dropdown, a switch, or a "special" chip such as `all`;
  - changes are highlighted;
  - "Use the default" removes a per-model override (llama.cpp);
  - the **Advanced** section is collapsed by default;
  - keys that aren't verified are greyed out.
- **Fit bar:** weights + KV + reserve against the basis (VRAM or RAM). It
  updates through `models.config_check` (debounced at 250 ms). It is red
  for an error and amber for a warning.
- **Buttons:**
  - **Use recommended**;
  - **Apply:** opens `ConnectionReview` (preserving 078's `busy` state),
    extended with a list of warnings to tick and a post-apply step:
    - "Restart now" (`providers.restart`, only with `can_control`) for
      `restart: service`;
    - "Reload the model" (`providers.reload_model`) for `model_reload`,
      only where the provider supports it;
    - "Takes effect on the next start" otherwise;
  - **Reset**;
  - **Undo**;
  - **Ask AI:** helper dropdown and a focus line using the shared `MicButton`
    and online dictation notice (as in 075/078). It fills your value with a
    badge "from Ask AI".
- **llama.cpp** keeps **"Measure and tune"**.
- **Advice-only providers** (vLLM, Strata, system Ollama): the
  recommendation plus a copyable snippet instead of Apply.
- Follow the maprisma-layout and maprisma-app skills: theme, corners, Esc
  and Backspace go back, eight languages, and a manual chapter "Configure a
  local provider".

## Acceptance

- **Step 0** is recorded here: real formats per installed provider,
  verified and unverified keys, unit flags, and the Ollama origin.
- **Recommender:** table tests over hardware fixtures × model fixtures × the
  4 profiles, with fixed numbers per case:
  - hardware: 24 GiB AMD (Vulkan, ROCm), 8 GiB NVIDIA (CUDA), 12 GiB with a
    model that doesn't fit, CPU only (16 GiB);
  - models: 7B Q4, 32B Q4, 70B Q4, and a sliding-window model;
  - plus llama.cpp total vs Ollama per-slot parallel, MAX_LOADED_MODELS,
    the offload order, and the clamps when trained < minContext;
  - a valid measurement wins; a stale mark, a skipped row or another
    profile recalculates.
- **Validator:** every rule, `special` values, float ranges, errors vs
  warnings (hard limits vs current free memory).
- **Writers** (each with fixtures): only its keys change; unknown keys and
  comments are kept; duplicates are merged; overrides can be removed;
  backup and Undo work; missing anchors are refused while overrides are
  created; a symlinked or foreign leaf file is refused; Jan writes both files;
  llama.cpp removes its own unit flags (with `daemon-reload` in the plan)
  and warns about a foreign unit; agent contexts are complete and Hermes
  keeps its `default_model`.
- **Routes:** `providers.restart` and `reload_model` return a task.
  `daemon-reload` runs after apply and after undo of a unit, without a
  restart. KoboldCpp's unload uses reload_config. A smart_ask candidate
  fills the cache, so its preview never gets `stale`. Any edit drops
  `config_proposal`. With NVIDIA fixtures the reserve is deducted only once.
  An old record without a reserve uses 1.5 GiB. Also: `config_check` without a cache gives `stale`; a preview with
  errors gives `ok: false`; size bounds hold; `providers.restart` follows
  the rules, `guardModel` and `daemon-reload`.
- **Ask AI:**
  - `column: "auto"` routing (both with and without `"area": "providers"`) and
    explicit `column: "providers"` route to `provider_config`, making at most
    2 helper calls (1 on explanation follow-up or early validation/rule refusal);
  - a fake helper's proposal: unknown keys are dropped, an invalid answer
    gives `bad_answer` (`status: "error"`) with no retry and never triggers
    `lookup`, and internal `facts` never reach the GUI or stay in
    `SmartProposals`;
  - follow-up context carries provider/model/profile/values (never
    `config_proposal`, file paths or secrets), preserves helper-switch consent,
    and re-collects fresh facts on refinement;
  - the `config_proposal` handle is bound and expires with a localized
    message (`_invalidRequest`), and any edited value drops it;
  - `action_rules` deny is enforced in `finalizeSmartAsk` (and before Call 2)
    without minting a handle or populating the cache, `configurable` is false
    without a schema, and 078's `performance` tests in `smart_card_test.dart`
    and `smart_window_test.dart` are updated to `provider_config` (including
    embedded review and Cancel-without-apply preserving prefilled values).
- **GUI tests:**
  - the action shows only for configurable providers, on all 3 entry
    points;
  - the model picker follows the schema scope;
  - edits update the fit bar;
  - errors disable Apply, and warnings need the tick;
  - the restart and reload options;
  - the advice-only snippet;
  - Esc; eight languages.
- Branch checks, full suites and build as in AGENTS.md. Screenshots (light
  and dark) of the Configuration page for llama.cpp, Ollama and one
  advice-only provider, outside the commits. Report the commits, test
  counts, the step-0 findings, the assumptions and the open points.

### Implementation verification (2026-11-19)

- Optional web research is available in central Ask AI and in each provider's
  Configuration action. It reuses a capable helper's read-only research form
  for the proposal call, with no extra invocation or retry. Sources are bounded
  HTTPS URLs. Local helpers remain available without research.
- Before removing an owned llama.cpp unit's hard flags, their verified values
  are transferred into the preset defaults and already-explicit model keys. This
  preserves the other models when changing only one setting; the reviewed edit
  is then applied. Foreign units and the user's wrapper are untouched.
- Saving or restoring a unit keeps its backup/Undo result even if the injected
  daemon-reload operation fails; the GUI reports the failure and skips the
  optional restart.
- Live read-only hardware snapshot: 16 physical / 32 logical cores, 61.7 GiB
  RAM (about 50.6 GiB available), 24.0 GiB discrete AMD VRAM with about 22.2 GiB
  available after other use. A second 512 MiB GPU is also detected. Free memory
  varies with other programs.

Balanced recommendations from one read-only collection (not applied):

| Provider / scope | Context | Cache / parallel | Other recommendations |
| --- | --- | --- | --- |
| llama.cpp defaults | 262144 total | q8_0 K/V, 1 | GPU all; flash on; batch 2048, physical batch 1024; threads automatic (-1) |
| llama.cpp Qwen3.8-27B-Q4_K_M | 49152 total (measured) | q8_0 K/V, 1 | GPU all; flash on; physical batch 512 |
| llama.cpp gemma-4-12B-it-QAT-Q4_0 | 262144 total | q8_0 K/V, 1 | GPU all; flash on; physical batch 1024 |
| llama.cpp gemma-4-26B-A4B-it-UD-Q4_K_M | 262144 total | q8_0 K/V, 1 | GPU all; flash on; physical batch 1024 |
| llama.cpp gemma-4-E2B-it-Q4_K_M | 131072 total | q8_0 K/V, 1 | GPU all; flash on; physical batch 512 |
| Ollama global (6 chat models) | 90112 per request | q8_0, 1 | Flash 1; maximum loaded models 1 |

The measured Qwen context is retained per the plan. Its analytical estimate
exceeds the currently available VRAM, so the validator raises a transient
memory warning requiring acknowledgement rather than silently discarding the
measurement. The other five providers are absent; their formats are tested
with fixtures, not claimed as live-tested installations. Screenshots likewise
use private fixtures, never a running provider.
