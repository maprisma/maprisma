## Round 1 (Antigravity, 2026-11-19, plan draft)

### 1. Critical — Fit math has four technical bugs that will over-recommend context (OOM) or double-penalize `parallel`
- **Where:** Plan §2 (lines 118–134), §3 (lines 141–147); code: `packages/maprisma_core/lib/src/context.dart:14, 178-234, 254-268`, `packages/maprisma_core/lib/src/llama_tune.dart:22, 463`.
- **What goes wrong and when:**
  1. **`parallel × ctx` is wrong for llama.cpp/Jan:** In llama.cpp (`--parallel N`), `ctx-size` is the *total* KV cache divided across `N` slots (`slot_ctx = ctx_size / parallel`), whereas in Ollama `OLLAMA_CONTEXT_LENGTH` is *per-slot* (`total_kv = ctx × parallel`). Applying `KV per token × parallel` to llama.cpp double-counts `parallel`, cutting recommended context by 2×–4× and causing the validator to reject valid configs.
  2. **Missing sliding-window `fixed` KV term and under-sized `512 MiB` overhead:** `context.dart:124, 260-262` subtracts both `fixed` (hybrid sliding-window layers in Gemma 3/4, Mistral) and `reserve = 1.5 GiB` (covering compute-graph buffers and desktop VRAM). `llama_tune.dart:22, 463` only uses `512 MiB` *after* subtracting real measured peak `used` + live `before` VRAM. Using `512 MiB` analytically without `fixed` will systematically OOM on 8–12 GiB cards and contradict `context.dart`'s existing `fits` numbers.
  3. **Ambiguous VRAM baseline & circular offload/context order:** §2 reads both `total VRAM` and `VRAM free now`, then formulas only say `VRAM`. Subtracting raw `vram_free` while *this* provider already holds a loaded model causes the recommender to think almost no VRAM is available and recommend CPU offload (and causes the validator's hard error to block Apply while the model is loaded). Also, full-vs-partial offload depends on `weights + KV`, which needs a target context before choosing `gpu-layers`, and clamping `at least 4096` can exceed `trained` context on smaller-context models or fail when weights alone exceed VRAM.
  4. **Single-cache `kvLayout`, `OLLAMA_MAX_LOADED_MODELS`, and `gpu-layers` off-by-one:** `context.dart:178` assumes symmetric K/V cache types, so editing `cache-type-v` independently will not update the fit bar or validator. For Ollama, `OLLAMA_MAX_LOADED_MODELS > 1` is missing from fit math, and no rule defines which installed model sizes global `OLLAMA_CONTEXT_LENGTH` (or what happens with 0 models). In §3 line 142, `gpu-layers <= block_count` rejects `block_count + 1` (needed in llama.cpp to offload `output.weight` when not using `all`).
- **Concrete fix:**
  - Make the KV slot multiplier engine-specific (`1` for llama.cpp/Jan total `ctx-size`; `parallel` for Ollama per-slot `OLLAMA_CONTEXT_LENGTH`).
  - Extend `kvLayout` to take `(cacheK, cacheV)` separately and always subtract `fixed` (× slot multiplier where per-slot).
  - Define available VRAM explicitly: `vram_total - max(analytical_reserve, other_vram + compute_overhead)` (separating this provider's own loaded VRAM via `GpuUsage`, with NVIDIA fallback to `vram_total - reserve` since `procVram` at `model_guard.dart:150` is amdgpu-DRM-only). Gate hard OOM *errors* on `vram_total` (or total RAM on CPU-only), not transient `vram_free`, and warn instead of blocking when `gpu-layers == 0` spills or exceeds `vram_free`.
  - Break the offload/context cycle with an explicit profile minimum target context (e.g., 8192/16384), compute partial offload layers from remaining VRAM after target KV + overhead, and clamp `min(trained, ...)` last. Allow `gpu-layers <= block_count + 1` (plus `all` / `-1`), and document how global `OLLAMA_CONTEXT_LENGTH` picks its sizing model (e.g., largest chat model or conservative default when 0 models are installed) and accounts for `OLLAMA_MAX_LOADED_MODELS`.

### 2. Critical — Provider config keys, types, and ownership have factual errors against the real engines and existing Maprisma installers
- **Where:** Plan §1 (lines 62–100), §2 (lines 108–109, 126), §3 (lines 141, 148); code: `packages/maprisma_core/lib/src/context.dart:615-825`, `packages/maprisma_core/lib/src/installers.dart:1050, 1277-1289, 1482, 1838`, `install_ctl.py:1148-1215`, `jan_ctl.py:3-88`, `provider_ollama.py:107-145, 181`, `provider_lmstudio.py:72`, `provider_koboldcpp.py:28, 79`, `provider_strata.py:118-120`, `packages/maprisma_core/lib/src/strata.dart:116-146`.
- **What goes wrong and when:**
  - **Schema `type` (`int | enum | bool`, line 68) cannot represent real keys:** `vLLM`'s `gpu-memory-utilization` is a `float` (`0.5–0.95`, §3 line 148); `llama.cpp`'s `gpu-layers` is `"all"` or `0..N` (`provider_llamacpp.py:71`); `KoboldCpp`'s `gpulayers` is `-1` (auto/all) or `0..N` (`installers.dart:1280`); `LM Studio`'s `gpuOffload` is a ratio/float or object, and its KV cache keys (`llm.load.llama.kCacheQuantizationType`, `context.dart:633-637`) store nested `{"checked": bool, "value": "..."}` objects rather than bare strings.
  - **Jan key name and writer target are wrong (line 84):** Jan's `model.yml` uses `ctx_size` (`context.dart:721`, `jan_ctl.py:53`), not `ctx_len`. More importantly, Maprisma's headless Jan service (`installers.dart:1482`) runs `jan-llama-worker --preset .../llamacpp/router.preset.ini` and **does not read `model.yml`**. Writing only `model.yml` will have zero effect on the running service unless `router.preset.ini` is updated in the same backup (as `janContextChanges` at `context.dart:755-774` does).
  - **llama.cpp `ExecStart` CLI flags can override `models.ini` (line 81):** `LlamaCppInstaller.unitText` (`installers.dart:1050`) hardcodes `--gpu-layers all --flash-attn on` on `ExecStart`. Changing `gpu-layers` or `flash-attn` in `models.ini` may be overridden by those unit flags (the exact hazard `model_slots.dart:362-370` had to strip `--models-max` for).
  - **System-installed Ollama is read-only, and flash-attention validation is too narrow (lines 82, 141):** Ollama installed via `pacman -S ollama` (`provider_ollama.py:181`) has no `~/.config/ollama/server.env` (`llm_tuning.dart:168, 203`) and must be `writable: false` with systemd drop-in advice, not just vLLM/Strata. Also Ollama has one combined `OLLAMA_KV_CACHE_TYPE` (so *any* quantized KV—`q8_0` or `q4_0`—requires `OLLAMA_FLASH_ATTENTION=1`), and KoboldCpp (`quantkv`: integer `0|1|2`, where `> 0` needs `flashattention: true`), LM Studio, and Jan all need flash-attention cross-key checks too.
  - **vLLM is not GGUF-based and has no Dart installer (lines 86, 108–109, 126):** `installers.dart:1838` registers vLLM as `RefusedInstaller`. vLLM serves Hugging Face safetensors (`VLLM_MODEL`), not `.gguf` files, so `readGguf` cannot size it; its `--kv-cache-dtype` takes `auto|fp8` (not `q8_0`/`q4_0`); `tensor-parallel-size` needs the GPU count (`detectGpu` only returns one GPU); and `gpu-memory-utilization` crashes vLLM on startup if `util × vram_total > vram_free` on a desktop GPU.
  - **Strata preset files may contain API keys (line 87):** `provider_strata.py:120` and `strata.dart:117` warn that `~/.config/strata/launch-presets/*.json` may hold an API key. Reading or forwarding preset contents into prompts/diffs risks violating `AGENTS.md`'s credential rule.
- **Concrete fix:**
  - Extend schema `type` to include `float` and `int_or_special` (e.g., `special: ["all"]` or `[-1]`) plus explicit per-key wire format metadata (`"0"|"1"`, `"on"|"off"|"auto"`, nested `{checked, value}`, integer enum `0|1|2`).
  - Fix Jan to `ctx_size` and dual-write `router.preset.ini` + `model.yml` (verifying every key in Step 0).
  - In llama.cpp, detect `--gpu-layers`/`--flash-attn` on `ExecStart`: strip them from Maprisma-owned `llama-server.service` (with `daemon-reload`) when overridden in `models.ini`, or emit a warning on foreign units/scripts.
  - Mark non-Maprisma Ollama as `writable: false` with drop-in advice; apply flash-attention checks to llama.cpp, Ollama, KoboldCpp, LM Studio, and Jan.
  - Scope vLLM to hardware-only (or HF `config.json`) sizing, `auto|fp8`, multi-GPU count check, and `vram_free / vram_total` headroom validation.
  - Keep Strata strictly allowlisted to non-secret fields or advice-only so API keys are never read, diffed, or sent to Ask AI.

### 3. Critical — Route contract gaps: synchronous `_dispatch`, stripped validation errors, `proposal` contradiction, and missing response fields
- **Where:** Plan §4 (lines 152–171); code: `packages/maprisma_core/lib/src/core.dart:2432-2565, 5264-5314`, `packages/maprisma_core/lib/src/protocol.dart:4-5`, `packages/maprisma_core/lib/src/core_tasks.dart:58`, `packages/maprisma_core/protocol/routes.json:1782-1828`, `tools/protocol.py:130-136`.
- **What goes wrong and when:**
  - **Validator `errors[]` cannot be returned on refusal (line 158):** `core.dart:5280-5305` turns `FormatException` into bare `{"error": {"code": "invalid_request"}}` (no message, no `errors[]`), and `ServiceError` carries only one plain string. Refusing `models.config_preview` by throwing loses field-level validator errors.
  - **Synchronous `_dispatch` cannot run async hardware/GPU probes:** `core.dart:5278` dispatches synchronously. `models.config_check` ("fast, no task") and `models.config_preview` cannot `await` `detectGpu()`, `GpuUsage`, or `LlamaTuner`, and calling `Process.runSync('nvidia-smi', ...)` or parsing GGUF headers on every edit would stall the core event loop. There is no mention of a cached snapshot (like `tuningFacts` at `core.dart:2448`) or what happens when Ask AI triggers a preview before `models.config` has populated the cache.
  - **Missing fields & `proposal` type mismatch:** `models.config`'s result omits `focus` (returned by `models.tuning`/`models.tune` in `routes.json:1790-1810`), `helpers[]` (needed for the Ask AI helper dropdown), `can_control` / `running` (needed for "Restart now"), and `untuned` / `measured` (needed for llama.cpp's "Measure and tune"). Meanwhile, `models.config_ask` returns `proposal: {values{}, reasons{}}` (an object with no handle id), contradicting `models.config_preview`'s `proposal?` param and §5 line 179 ("the proposal id travels with the step").
  - **Unbounded model list & request size:** Unlike `llm_tuning.dart:352` (`rt.models.take(40)`), the plan sets no model cap or `focus` length limit, risking the 64 KiB `maxRequest` (`protocol.dart:4`), 1 MiB `maxFrame`/`maxResponse` (`core_tasks.dart:58`, `protocol.dart:5`), and 256 KiB worker stdin (`core.dart:2520`) limits.
  - **Inaccurate `tools/protocol.py` step (line 168):** `tools/protocol.py` has no registration list for RPC routes (`GUI_NON_ROUTES` is only for `providers.run` worker ops); routes are discovered from `core.dart` (`portedRoutes` + `_dispatch`) + `route_probe.dart`, and `kind()` (`tools/protocol.py:130-136`) already maps `config`, `config_check`, `config_ask` to `read` and `config_preview` to `preview`.
- **Concrete fix:**
  - Make `models.config_preview` return `{ok: false, errors: [...], warnings: [...]}` (with no `plan` handle) on validator errors, while still throwing `FormatException` for malformed wire params.
  - Cache bounded per-provider facts (`rt.models.take(40)`) in the core when `models.config` finishes (with expiry, as `tuningFacts` does) so `models.config_check` and `models.config_preview` run pure synchronous math against cached facts; specify a clean `stale` error if the cache is missing/expired.
  - Add `focus`, `helpers[]`, `can_control`, `running`, `untuned` to `models.config` in `routes.json` (`source: "manual"`), cap `focus` (e.g. ≤ 500 chars) and `values` entries, and separate the opaque `proposal` handle string from `{values, reasons}` in `models.config_ask`'s result.

### 4. High — Action rules refer to a nonexistent `maprisma.provider_config` toggle instead of `action_rules`, leaving Ask AI candidates unchecked
- **Where:** Plan §5 (lines 179–182), §4 (lines 169–170); code: `packages/maprisma_core/lib/src/action_rules.dart:6-16, 283-285`, `packages/maprisma_core/lib/src/smart_card.dart:168-175`, `packages/maprisma_core/lib/src/core.dart:4459-4507`, `packages/maprisma_core/test/action_rules_test.dart:233-250`.
- **What goes wrong and when:** Maprisma has no `maprisma.provider_config` action id and no `maprisma-settings` toggle mechanism; every permission check uses `settings.json['action_rules']` with `{effect, action, category, item, agent}` (`action_rules.dart:6-73`). Because `smartCandidateChecks` (`smart_card.dart:168`) returns `const []` for `performance`, adding `provider_config` without mapping it in `smartCandidateChecks` lets `_dropRefused` (`core.dart:4459`) pass config-changing candidates even when the user has denied provider updates. Additionally, `action_rules_test.dart:233-246` requires every `preview` route in `routes.json` to be in `actionChecks` or `rulesExempt`.
- **Concrete fix:** Remove the nonexistent `maprisma.provider_config` / `maprisma-settings` item. Add `'models.config_preview'` to `actionChecks` (`action_rules.dart:283-285`) returning `[ActionCheck('update', 'providers', text('key'))]`, add `'provider_config'` to `smartCandidateChecks` returning the same `ActionCheck`, and add a test entry in `action_rules_test.dart`.

### 5. High — Ask AI (`map.smart_ask` & `models.config_ask`) conflicts with `smart_card.dart`'s pipeline and no-retry token rule
- **Where:** Plan §5 (lines 172–194); code: `packages/maprisma_core/lib/src/smart_card.dart:26-32, 1049-1157, 1997-2090, 2172-2190, 2280-2324`, `packages/maprisma_core/lib/src/core.dart:3165-3175, 3284-3299`.
- **What goes wrong and when:**
  - **`smartProviders` has none of the facts required to build `provider_config`:** `core.dart:3284-3299` sends only `{key, name, installed, running, install, update, start, stop, performance}` to `map.smart_ask` in the Providers column—no hardware, models, GGUF metadata, config schema, or recommender output. The plan claims `map.smart_ask` builds a prefilled `provider_config` candidate from `models.config_ask`, without specifying how the `smartAsk` worker (`smart_card.dart:2172`) runs a two-step collect + recommend + propose pipeline.
  - **Silent retry violates `smart_card.dart:30-31`:** `smart_card.dart` enforces *"one click on Ask, at most two answers for it, never a retry."* Plan §5 line 186 adds an automatic retry on invalid JSON; inside a two-step `map.smart_ask` flow that becomes up to 3 LLM calls per click.
  - **Provenance of `proposal?` is undefined:** Because `models.config_preview` accepts arbitrary `values{}` for manual edits, the plan never defines what passing `proposal?` enforces (e.g., core-side validation against a proposal store, what happens when the user edits one field from Ask AI, or expiry).
  - **Helper runner mismatch:** `models.tuning_ask` uses `research` (`llm_tuning.dart:608`) and `_aiHelpers()`, whereas `smartHelpers()` (`core.dart:3165`) uses `closed` + `rewrite` (`smartAgent`).
- **Concrete fix:** Define the explicit two-step `smartProviders` worker flow (step 1: pick `{action: "provider_config", provider, model?, profile?, focus?}`; step 2: collect + recommend + single config-proposal prompt via `smartAgent`, ≤ 2 calls total, **no automatic retry**; return `bad_answer` immediately on invalid JSON). Have `models.config` return `smartHelpers()` and run `models.config_ask` through `smartAgent` (no tools). Define `proposal` as a core-issued provenance handle stored with expiry and cleared by the UI whenever the user modifies a proposed value.

### 6. High — "Restart now" and writer safety rules have missing protocol support and internal contradictions
- **Where:** Plan §4 (lines 161–163), §6 (lines 224–225), Acceptance (lines 250–256); code: `packages/maprisma_core/lib/src/connect_apply.dart:130-158, 222-279, 389-391`, `packages/maprisma_core/lib/src/provider_ops.dart:161-171, 277-295`, `packages/maprisma_core/lib/src/model_guard.dart:405-416`, `packages/maprisma_core/lib/src/llm_tuning.dart:237-243`, `packages/maprisma_core/lib/src/system_actions.dart:185-193`, `flutter_app/lib/connections_view.dart:510-606`.
- **What goes wrong and when:**
  - **"Restart now" has no execution path and misses safety checks:** `ConnectionReview` (`connections_view.dart:510-606`) has neither a warning-acknowledgment checkbox nor a "Restart now" toggle. `ProviderOps` (`provider_ops.dart:161-171`) has no `runtime.restart` operation; running `runtime.stop` + `runtime.start` must still pass `action_rules` (`stop`/`start` on `providers`), warn/guard when an agent is actively generating (`guardModel`, `model_guard.dart:405`), and run `systemctl --user daemon-reload` whenever a `.service` unit file changed (`connections.apply` never reloads systemd). For `restart: "model_reload"` providers (LM Studio, KoboldCpp with `stays_up: true`), restarting the service is wrong—unloading/reloading the model is what applies changes.
  - **"Missing file is refused" contradicts creatable per-model files:** Acceptance line 254 requires refusing missing files, yet LM Studio has no `<ident>.json` until the first write (`context.dart:846`), and `models.ini` may not exist yet (`context.dart:416`). Also note `ConfigFiles.read` (`connect_apply.dart:145`) returns `""` on `ENOENT` instead of throwing, whereas `LlmTuning._read` (`llm_tuning.dart:237`) uses raw `File.readAsStringSync()` (bypassing `O_NOFOLLOW` and `uid` checks!).
  - **Existing writers can drop comments or leave duplicate keys:** `envWith` (`system_actions.dart:191`) only replaces the *first* `NAME=...` line (leaving a later duplicate that wins in systemd); `iniText` (`context.dart:443`) drops inline comments and cannot unset a per-model override.
- **Concrete fix:** Specify the review-dialog extension (`warnings[]` tick + optional post-apply action: `daemon-reload` if a unit changed, `stop`+`start` gated on `can_control`/`action_rules`/`guardModel` for `restart: service`, or model unload for `restart: model_reload`). Use `ConfigFiles.read` (never `LlmTuning._read`) plus ancestor symlink/ownership checks (`checkTrusted`) on all writers; separate must-exist ownership anchors (`ollama/server.env`, existing `.kcpps`, `model.yml`, `vllm.service`) from creatable override files (LM Studio `<ident>.json`, Maprisma `models.ini`). Fix `envWith` to handle duplicate keys cleanly.

### 7. High — "All models (default)" picker and agent-context sync break on per-model providers and Hermes
- **Where:** Plan §4 (line 158), §6 (line 208); code: `packages/maprisma_core/lib/src/context.dart:580-825`, `packages/maprisma_core/lib/src/core.dart:2378-2411`, `packages/maprisma_core/lib/src/llm_plans.dart:90-122, 492-586`.
- **What goes wrong and when:**
  - §6 line 208 offers `"All models (default)"` for every per-model provider, but only llama.cpp (`models.ini` `[*]`) has a shared defaults section. LM Studio, KoboldCpp, and Jan (`model.yml`) only have per-model files where each model has different sizes, layer counts, and KV bytes/token—there is no shared file to write and no single fit estimate across heterogeneous models.
  - In `models.config_preview` (line 158), updating connected agents via `llm.transform(adapter.command, old, rt, '', false, false, contexts)` (`core.dart:2398`) will wipe out `context_length`/`contextWindow` for every *other* model of that provider if `contexts` only contains the single edited model, and for Hermes (`llm_plans.dart:106`) passing `model = ''` overwrites `default_model:` with an empty value.
- **Concrete fix:** Only show `"All models (default)"` (`model: "*"`) when the provider schema supports global/default entries (llama.cpp); for strictly per-model providers (LM Studio, Jan, KoboldCpp), require selecting a concrete model (defaulting to the first/active model). Only include agent-config changes in `models.config_preview` when an effective context value changed, populate `contexts` with the effective context of *all* models of `rt`, and preserve Hermes's existing `default_model` instead of passing `''`.

### 8. Medium — Compatibility gaps in `tools/adapter-assets.py`, `providers.snapshot`, `llm-tuning.json`, and Linux hardware probes
- **Where:** Plan Decisions (line 18), Inventory (line 33), §1 (lines 76–77), §2 (lines 104–112), §4 (lines 164–167), §6 (lines 197–204); code: `tools/adapter-assets.py:23`, `packages/maprisma_core/lib/src/read_service.dart:358-359`, `packages/maprisma_core/lib/src/provider_facts.dart:16-68`, `packages/maprisma_core/lib/src/llama_tune.dart:509-562`, `packages/maprisma_core/lib/src/health_report.dart:144-175`, `packages/maprisma_core/lib/src/context.dart:29-41`, `provider_llamacpp.py:67-76`, `flutter_app/lib/providers_view.dart:169`, `flutter_app/lib/main.dart:1488-1580, 1852-1951, 2474-2494, 4237-4246`.
- **What goes wrong and when:**
  - **`tools/adapter-assets.py:23` does not export `config`:** Plan line 76 states *"the generator already carries them"*, which is false—line 23 explicitly lists engine keys (`tuning`, `tuning_per_model`, etc.) and must be updated. Also, `provider_facts.dart` only toggles built-in provider visibility; third-party provider add-ons cannot declare arbitrary Dart writers or runtime `config` schemas yet (Decisions line 18).
  - **`providers.snapshot` (`read_service.dart:358`) still only emits `tunable`:** Plan §4 only changes `performance` → `configurable` in `map.smart_ask`, omitting `providers.snapshot` (which gates `ProvidersView` at `providers_view.dart:169` and the map box button at `main.dart:2474-2484, 4237`). Also note `_nodeMenu` (`main.dart:1488-1580`) opens `_addonMenu` (which currently has no Performance/Configure action), while the map box uses an inline `Icons.speed` button (`main.dart:4237`).
  - **`llm-tuning.json` precedence ignores `mark`, skipped rows, and profile overrides:** `llama_tune.dart:509-549` stores `{mark, ctx, ubatch, pp, tg}` at `parallel=1` (or `{mark, reason}` when skipped). Letting any record win unconditionally (§2 line 111) will apply stale measurements after a llama.cpp build change, fail on skipped rows lacking `ctx`, or ignore `parallel > 1` / `q4_0` in non-default profiles.
  - **Linux RAM/CPU/GGUF reader gaps:** `health_report.dart:148-172` only reads `MemTotal` and logical cores (`Platform.numberOfProcessors`). Reading `/proc/meminfo`'s `MemFree` instead of `MemAvailable` severely under-reports usable RAM on Linux; physical cores require `/sys/devices/system/cpu/cpu*/topology` (or `/proc/cpuinfo` unique `(physical id, core id)`) with a logical-core fallback. `context.dart:29-41` (`readGguf`) does not yet read `general.file_type` (quantization). (Minor inventory nit: `provider_llamacpp.py:67-76` has 8 tuning keys, not 7.)
- **Concrete fix:** Update `tools/adapter-assets.py:23` to serialize `engine.config`, add `configurable` to `providers.snapshot` (keeping `tunable` for compatibility) and its `routes.json` shape, wire the Configure entry into both the map box/menu (`_addonMenu` + `Icons.speed`) and `ProvidersView`/`MapSmartCard`, and clarify add-on scope in Decisions. Only let `llm-tuning.json` win when `record['mark'] == currentBuild.mark` and `ctx`/`ubatch` are present, recomputing `ctx` when profile `parallel` or KV cache differs. Use `MemAvailable`, parse physical CPU topology with fallback, and add `general.file_type` to `readGguf`.

### Answers (Claude, 2026-11-19)

I checked in the code: Jan uses `ctx_size`, the unit has hard-coded flags (`installers.dart:1050`), the 1.5 GiB reserve (`context.dart:14`), vLLM is a RefusedInstaller, the no-retry rule (`smart_card.dart:30`), only MemTotal is read. All 8 are **accepted**; the plan is rewritten as v2:

1. Memory model: llama.cpp/Jan total vs Ollama per slot, fixed term, 1.5 GiB reserve, separate K/V types, an explicit free baseline, the offload order with target contexts, clamps, blocks+1, MAX_LOADED_MODELS.
2. Schema types float and int_or_special, wire formats. Jan is ctx_size plus the preset. llama.cpp unit flags. System Ollama is read-only. Flash-attention rules for every provider. vLLM and Strata are advice-only, and Strata uses an allowlist (no secrets).
3. `{ok:false, errors}` instead of a throw; check and preview run against the cache with `stale`; new result fields; the proposal handle is separate; bounds; the protocol.py step corrected.
4. No `maprisma.provider_config`: action_rules with actionChecks and smartCandidateChecks.
5. Two-step map.smart_ask with at most 2 calls and no retry; smartAgent and smartHelpers; proposal provenance defined.
6. `providers.restart` with rules, guardModel and daemon-reload; ConnectionReview with a warning tick; anchor vs override files; ConfigFiles.read with checkTrusted; envWith and iniText fixed.
7. The model picker follows the schema scope; agent contexts are complete; Hermes keeps default_model.
8. adapter-assets exports config; `configurable` in providers.snapshot; both map entry points; the validity of llm-tuning.json records; MemAvailable, physical cores, file_type.

## Round 2 (Antigravity, 2026-11-19, plan v2)

All 8 round-1 findings were incorporated into v2, but the v2 design introduces 4 concrete contract/logic bugs against `main` that block implementation:

### 1. Critical — `providers.restart` omits `{task}`, breaks `daemon-reload` wiring (including on Undo), and leaves `model_reload` unimplemented for KoboldCpp
- **Where:** Plan §5 (lines 214, 216, 241–243), §7 (lines 298–303); code: `packages/maprisma_core/lib/src/core.dart:2911-2915, 4355-4378, 4739, 5159-5178, 5278`, `packages/maprisma_core/lib/src/provider_ops.dart:161-171, 267-295, 323-359`, `packages/maprisma_core/lib/src/plan_worker.dart:233-286`, `packages/maprisma_core/lib/src/core_tasks.dart:320-342`, `provider_koboldcpp.py:64-68`, `tools/protocol.py:41-43`, `packages/maprisma_core/test/action_rules_test.dart:247-254`.
- **What goes wrong:**
  1. **Async work in synchronous `_dispatch`:** `core.dart:5278` dispatches synchronously, while `ProviderOps.stop()` / `start()` (`provider_ops.dart:267-295`) and `guardModel()` (`model_guard.dart:405`) are `Future`-based subprocess/HTTP calls (up to 30–90 s). Unlike `models.config` and `models.config_ask` (lines 212, 215), §5 line 216 omits `{task}` for `providers.restart`. Running stop+start synchronously would stall the core RPC loop, and synchronous `guardModel` (`core.dart:4355`) spawns a blocking subprocess.
  2. **Broken `reload_units` / `daemon-reload` path:** `models.config_preview` returns `reload_units` (line 214), but `providers.restart` accepts only `key` (line 216) and never receives `reload_units` (nor does `connections.apply` record a per-provider dirty flag). Worse, if the user applies a llama.cpp unit edit and skips "Restart now" (or restarts later via `providers.run`, or reverts the `.service` file with `connections.undo`), `systemctl --user daemon-reload` never runs and systemd keeps the stale unit in memory.
  3. **Undefined `model_reload` action (KoboldCpp vs LM Studio):** §7 line 302 offers `"Reload the model"` for `restart: model_reload` (LM Studio, KoboldCpp) without naming a route/operation. In `provider_ops.dart:324, 358`, KoboldCpp refuses `model.load`, and `ProviderOps.unloadModel` falls through to `stop(rt)` instead of calling `/api/admin/reload_config` (`{"filename": "unload_model"}`, `provider_koboldcpp.py:67`).
- **Fix:**
  - Make `providers.restart` return `{task}` (running `guardModel`, optional `daemon-reload`, `stop`, and `start` in the worker, like `providers.run`), add `restart` to `CHANGE` in `tools/protocol.py:41`, and add an explicit test in `action_rules_test.dart` covering **both** `stop` and `start` checks (line 248 only asserts `.first`).
  - Run `systemctl --user daemon-reload` automatically inside `connections.apply` (`plan_worker.dart:applyPlan`) and `connections.undo` whenever a `.service` file is written or restored (or expose an explicit reload step like `models.slots_reload` that runs immediately after apply/undo regardless of restart).
  - Specify what `"Reload the model"` does: either add KoboldCpp's `/api/admin/reload_config` unload to `ProviderOps.unloadModel` and run guarded `model.unload` (with optional `model.load` where `can_load` is true), or make `model_reload` an informational hint rather than an active button for providers without reload support.

### 2. Critical — `map.smart_ask` → `provider_config` breaks across the worker/core boundary and contradicts `proposal` provenance
- **Where:** Plan §5 (lines 212–215), §6 (lines 247–266); code: `packages/maprisma_core/lib/src/core.dart:3284-3299, 3366-3466, 3643-3720, 4734-4735`, `packages/maprisma_core/lib/src/smart_card.dart:168, 1060, 1126-1157, 2172-2190, 2280-2324`, `packages/maprisma_core/lib/src/action_rules.dart:6-16, 228-382`, `flutter_app/lib/map_smart_card.dart:2885-2925`.
- **What goes wrong:**
  1. **Cross-process cache & handle gap, plus undefined click flow:** `map.smart_ask` executes in a separate worker process (`core.dart:3366`), which has no access to the core process's in-memory facts cache or proposal handle store. If the worker emits a `provider_config` candidate `{key, model?, profile, values{}, reasons{}, proposal}` (line 259–260) without returning the collected facts to `core.dart`'s finalize callback (`core.dart:3369`) to populate the core facts cache and mint the handle, calling `models.config_preview` will fail with `{error: "stale"}` or unknown proposal. Moreover, `SmartProposals.keep` (`smart_card.dart:2286-2310`) already attaches a top-level `'proposal'` handle to `map.smart_ask` results and strips `'action'`, and the plan never specifies what clicking Review on a `provider_config` candidate in `map_smart_card.dart:2891` does (open the Configuration page prefilled with the proposal vs call `models.config_preview` directly—and how advice-only providers like vLLM, Strata, and system Ollama are handled).
  2. **`smartProviders` action/key mismatch:** Changing `smartProviders` from `'performance'` to `'configurable'` (`core.dart:3297`, Plan lines 260–261) breaks `smart_card.dart:1127` (`p[action] == true`), since the LLM outputs `action: "provider_config"` while the fact key is `"configurable"`.
  3. **Self-contradictory `proposal` binding & nonexistent "AI step" rules (lines 262–266):** `proposal` is a single handle bound to `{key, model, values}`, yet line 265 says editing a proposed value *"drops the proposal from those keys (they become manual)"*. If the GUI still passes `proposal` alongside modified `values`, the `{key, model, values}` binding check will refuse the preview. In addition, `action_rules.dart` has no separate rule dimension for "an AI step" (`ActionCheck.agent` is the target agent, not the helper); `_dispatch` enforces the same `actionChecks('models.config_preview', ...)` (`ActionCheck('update', 'providers', key)`) regardless of `proposal`.
- **Fix:**
  - Have the `map.smart_ask` worker return the collected facts with the `provider_config` candidate so `core.dart`'s finalize callback populates the core facts cache and mints the config proposal handle (distinct from `SmartProposals`'s top-level `proposal`), and specify that clicking Review opens the Configuration page prefilled with `{model, profile, values, reasons, config_proposal}` (which naturally supports advice-only providers too).
  - In `smartProviders`, map `action == 'provider_config'` explicitly to `p['configurable'] == true` (updating `smartProvidersPrompt`, `smartCandidateChecks`, and `map_smart_card.dart:2892`).
  - Resolve the provenance rule: either drop `proposal` entirely on any manual edit (so any edited preview becomes manual), or define partial-match validation for unchanged keys only; remove *"and the `action_rules` of an AI step"* and rely on `actionChecks('models.config_preview', ...)` and `smartCandidateChecks('provider_config')`.

### 3. High — Fit math in v2 relies on a nonexistent "measured reserve" in `llm-tuning.json` and double-subtracts `1.5 GiB` on NVIDIA
- **Where:** Plan §2 (lines 123–126), §3 (lines 143–144, 175–179); code: `packages/maprisma_core/lib/src/llama_tune.dart:470-480, 509-549`, `packages/maprisma_core/lib/src/model_guard.dart:150-180`.
- **What goes wrong:**
  1. **`llm-tuning.json` does not store a measured reserve:** §3 lines 144 and 177–179 use a "measured reserve" from `llm-tuning.json` to recalculate context when `parallel` or KV cache differs from the record. However, `withMeasurement` (`llama_tune.dart:540-544`) discards `used`, `cache`, `flash`, and `batch`, saving only `{mark, build_path, version, kind, date, ctx, ubatch, pp, tg}` (as Plan Inventory lines 53–54 already notes). Existing `llm-tuning.json` files have no reserve field.
  2. **Double-subtracting `reserve` on NVIDIA:** §2 lines 123–126 defines the free baseline as `vram_total − other_used` with *"on NVIDIA and others the fallback is a fixed reserve (see below)"*, and §3 line 143 adds `+ reserve` (`1.5 GiB`) into `need`. Because `procVram` (`model_guard.dart:150-180`) is amdgpu-only and returns `0` on NVIDIA, subtracting `1.5 GiB` in `avail` *and* adding `1.5 GiB` in `need` deducts **3.0 GiB** on NVIDIA cards (severely undersizing the 8 GiB NVIDIA acceptance fixture).
- **Fix:**
  - Either extend `withMeasurement` to also persist `used` (or derived `reserve`) **and** define the fallback for existing records without it (e.g., `1.5 GiB`, or back-calculate from `vram_total − weights − kv(record.ctx, q8_0)` clamped `>= 512 MiB`), or state the back-calculation formula explicitly.
  - Define the NVIDIA/non-amdgpu baseline as `other_used = 0` (`avail = vram_total`), so the single `reserve = 1.5 GiB` in `need` is subtracted once.

### 4. Medium — `checkTrusted` rejects config file paths (directories only) and follows non-leaf symlinks; llama.cpp foreign-unit writability is contradictory
- **Where:** Plan §1 (line 99), §5 (lines 223–226), Acceptance (line 333); code: `packages/maprisma_core/lib/src/installers.dart:350-418`, `packages/maprisma_core/lib/src/connect_apply.dart:130-158`.
- **What goes wrong:**
  1. **`checkTrusted` throws on files:** `installers.dart:368-370, 415` asserts the final component is a directory (`mode & typeMask != dirType` → `StateError('$where is not a folder')`). Passing a config file path directly to `checkTrusted` will fail on every real config file. In addition, `checkTrusted` (`installers.dart:402-414`) *follows* symlinks in non-leaf ancestors (checking owner/permissions) and only rejects a symlink at the leaf, which conflicts with Acceptance line 333 if a test expects non-leaf symlink ancestors to be refused.
  2. **llama.cpp writability contradiction:** §1 line 99 states both *"A foreign unit or script gives a warning: 'the unit's flags win'"* and *"Writable when: `models.ini` may be created; the unit must be Maprisma's own"*, while §5 line 226 lists *"the llama.cpp unit"* as a required anchor file. It is contradictory whether a foreign/unitless llama.cpp installation can still write `models.ini` (with a warning, without editing the unit) or is read-only.
- **Fix:**
  - Specify `checkTrusted(p.dirname(path))` on the parent directory plus `ConfigFiles.read(path)` (`O_NOFOLLOW` + `uid` on the leaf file), and clarify whether trusted ancestor symlinks are allowed (matching `checkTrusted`) or strictly rejected by a dedicated helper.
  - Clarify §1 line 99 and §5 line 226: `models.ini` is writable for any installed llama.cpp (with a warning when a foreign unit/script sets overriding flags); only editing `ExecStart` requires a Maprisma-owned unit to exist as an anchor.

### Answers (Claude, 2026-11-19)

All 4 **accepted**, plan v3:

1. `providers.restart` and the new `providers.reload_model` return `{task}`. `daemon-reload` runs inside `connections.apply`/`undo`. KoboldCpp unloads through reload_config. CHANGE and the test assert both checks.
2. The worker returns the facts, finalize fills the cache and mints `config_proposal`. Review opens the prefilled page. configurable is mapped to provider_config. Any edit drops the proposal; there is no separate AI-step rule.
3. `withMeasurement` stores used and reserve, old records use 1.5 GiB. NVIDIA: other_used = 0, so the reserve is deducted once.
4. checkTrusted on the parent folder, and ConfigFiles.read for the leaf file. models.ini is writable for every llama.cpp; the unit is needed only for ExecStart.

## Round 3 (Antigravity, 2026-11-19, plan v3)

Round-2 findings 1, 2, and 4 are resolved. Finding 3's NVIDIA double-subtraction is resolved, but the new formula added for the measured llama.cpp `reserve` introduces one blocking math/wiring bug:

### 1. High — Derived llama.cpp `reserve` subtracts `kv(record.ctx, q8_0)` from `llama-bench`'s 2064-token `used` VRAM and omits `tuneMargin`
- **Where:** Plan §3 (lines 146–149, 182–184); code: `packages/maprisma_core/lib/src/llama_tune.dart:21-22, 372-378, 460-480, 526-549`.
- **What goes wrong:**
  1. In `llama_tune.dart:460-464`, `used = peak - before` is the peak VRAM delta of the short `llama-bench` run at `tokens = tunePrompt + tuneMemGen` (`2048 + 16 = 2064` tokens, line 21 & 462), **not** at `record.ctx` (the extrapolated max context that fills the card, e.g. 65536–131072 tokens). Evaluating `used − weights − kv(record.ctx, q8_0)` yields a large negative number whenever `record.ctx > 2064`, so clamping to `≥ 512 MiB` collapses `reserve` to `512 MiB` on almost every model and discards the real compute-graph/runtime overhead.
  2. Even using `tunePrompt + tuneMemGen`, `used − weights − kv(2064, ...)` is only the raw runtime overhead without `tuneMargin` (`512 MiB`, `llama_tune.dart:22, 463`). Omitting `+ tuneMargin` makes recalculated context over-allocate by `512 MiB` relative to `llama_tune.dart:463-464` (and OOM on models whose runtime overhead exceeds `512 MiB`).
  3. `withMeasurement(record, measured, now)` (`llama_tune.dart:526-549`) has neither `weights` nor GGUF metadata, and `_one()` (`llama_tune.dart:372-378, 470-480`) measures with `cacheK`/`cacheV` from `models.ini` rather than hardcoded `q8_0`.
- **Fix:** Compute `reserve` inside `LlamaTuner._one()` (where `file` size/`weights`, `meta`, `cacheK`, `cacheV`, and `used` are available):
  - `overhead = max(0, used − weights − kv(tunePrompt + tuneMemGen, cacheK, cacheV))`
  - `reserve = overhead + tuneMargin` (already `≥ 512 MiB`, and reproduces `llama_tune.dart:463-464` exactly when recalculated at the measured profile).
  - Return `reserve` (plus `cache_k` / `cache_v`) from `_one()` so `withMeasurement` persists `{used, reserve, cache_k, cache_v}` directly. Old records without `reserve` keep the `1.5 GiB` fallback (and assume `q8_0`).

### Optional notes (non-blocking)
- **`connections.undo` location (§5 lines 246–249):** `connections.apply` runs in `plan_worker.dart` (`applyPlan`), while `connections.undo` runs synchronously in `packages/maprisma_core/lib/src/core_tasks.dart:401` (`Connections.undo` → `ConfigFiles.undo`). Give `Connections` (and `applyPlan`) an injectable `daemon-reload` hook so unit tests can assert it without invoking real `systemctl`.
- **Strip internal facts in `map.smart_ask` finalize (§6 lines 276–280):** `SmartProposals.keep` (`smart_card.dart:2299-2309`) forwards every result/candidate field except `candidate['action']` to the GUI. Either carry the worker's collected facts inside `candidate['action']` or remove the internal facts field in `core.dart:3369` after filling the core cache.
- **Minor §5 wording & `reload_model` rule (lines 253–260):** Line 254 correctly adds both `restart` and `reload_model` to `CHANGE` in `tools/protocol.py:41` (`reload` is `$`-anchored, so `reload_model` needs its own entry); drop the leftover *"so only `restart` needs a look"* on line 259–260. Also consider checking `ActionCheck('stop', 'models', model)` / `ActionCheck('start', 'models', model)` on `providers.reload_model` to match `action_rules.dart:164-165` (`model.unload`/`model.load`).

### Answers (Claude, 2026-11-19)

All accepted, plan v4: the reserve is computed in `_one()` from the bench token count plus `tuneMargin`, with cache_k/v stored. Injectable daemon-reload hook for apply and undo. Internal facts are removed before the GUI sees them. The protocol.py wording is cleaned up. reload_model checks stop/start on models. The finding was concrete and its fix is taken over exactly, so no round 4.

## 077 vs 078 (Antigravity, 2026-11-19)

### 1. Concrete conflicts and outdated assumptions in 077

1. **Auto-routing (`column: "auto"`) and `smartAutoPrompt` are missing from 077**
   - In 078, the central Ask AI composer (`showBar: false`) always sends `column: 'auto'` with optional `context` (`flutter_app/lib/map_smart_card.dart:1175-1183`, `packages/maprisma_core/protocol/routes.json:1398-1416`, `packages/maprisma_core/lib/src/core.dart:3282-3305`).
   - `smartAsk` calls `smartAutoPrompt(facts)` (`packages/maprisma_core/lib/src/smart_card.dart:2131-2152`, invoked at `2242-2245`), NOT `smartProvidersPrompt`. `smartAutoPrompt` currently hard-codes `Use provider:key with install, update, start, stop, performance. Performance checks slow local models and tuning.` (`smart_card.dart:2144-2145`).
   - 077 section 6 (`077-provider-config.md:283-284, 300`) specifies `{action: "provider_config", provider, model?, profile?, focus?}` without `"area": "providers"` and only mentions updating `smartProvidersPrompt`. In `smartAsk` (`smart_card.dart:2244, 2268-2291`), any action not caught before the `switch (area)` requires `area == 'providers'` or throws `FormatException('Unknown operation')` (`smart_card.dart:2290`). Both `smartAutoPrompt` and `smartProvidersPrompt` must advertise `provider_config` (with `"area": "providers"` in `smartAutoPrompt`), and `smartAsk` must also route `action == 'provider_config'` to `smartProviders` directly if `"area"` is omitted (matching `addon` at `smart_card.dart:2263-2264`), normalizing `area = 'providers'`.

2. **`provider_config` candidate shape breaks `smartCandidateChecks`, `_buildProposal`, and follow-up evidence (security + UI bug)**
   - 077 (`077-provider-config.md:293-294`) defines the candidate as `{key, model?, profile, values{}, reasons{}, config_proposal}`.
   - **Rule-bypass bug:** `smartCandidateChecks` (`packages/maprisma_core/lib/src/smart_card.dart:135-137`) starts with `final action = candidate['action']; if (action is! Map) return const [];`. In `_dropRefused` (`packages/maprisma_core/lib/src/core.dart:4635`), `smartCandidateChecks(c).every(ok)` evaluates `[].every(ok) == true`, so omitting `action: {'kind': 'provider_config', ...}` silently bypasses `action_rules` deny rules.
   - **UI & handle requirements:** `SmartProposals.candidate` (`smart_card.dart:2406`) and `_buildProposal` (`flutter_app/lib/map_smart_card.dart:3445-3495`) require `id`, `kind: 'provider_config'`, `title`, `subtitle`, `reason`, `fit: 'ok'`, `size: 0` (plus `proposal` from `SmartProposals.keep`, which strips `action` at `smart_card.dart:2391`). Without `title`, `_responseField` (`map_smart_card.dart:2686`) also emits `'null '` into follow-up context.

3. **`finalizeSmartAsk` pipeline location, order, and facts/handle lifecycle**
   - 077 (`077-provider-config.md:289`) cites `core.dart:3369`. In 078, `tasks.startPrivate('map.smart_ask', body, finalizeSmartAsk)` is at `packages/maprisma_core/lib/src/core.dart:3494`, and `finalizeSmartAsk` is at `core.dart:4585-4586`:
     `smartProposals.keep(smartWorded(_dropRefused(result), i18n.text))`.
   - Because `_dropRefused` (`core.dart:4590-4656`) runs first and `SmartProposals.keep` (`smart_card.dart:2371-2395`) forwards every candidate key except `'action'`, carrying internal collected facts inside `candidate['action']['facts']` and processing them **after** `_dropRefused` (before `smartProposals.keep`) ensures: (a) denied candidates never populate the facts cache or mint a `config_proposal` handle, (b) `'facts'` is removed from `action` before `keep` so `SmartProposals` never retains raw facts in memory for 30 minutes and never leaks them to the GUI, and (c) if every candidate is denied, `_dropRefused` preserves `helper` and `local` (`core.dart:4647-4648`) so follow-up helper-switch logic stays accurate.

4. **Two-call rule, worker collector plumbing, progress stages, and `summary` propagation**
   - The two-call rule comment is still at `packages/maprisma_core/lib/src/smart_card.dart:30-31`. In 078 `column: 'auto'`, Call 1 is `smartAutoPrompt` (`smart_card.dart:2243`) and `smartAsk` passes `decision: decision` into `smartProviders(facts, agent, decision: decision)` (`smart_card.dart:2270`, consumed at `1090-1091`), so `smartProviders` makes zero classification calls in `auto` mode and at most one proposal call (Call 2) for `provider_config` — keeping the total at ≤ 2 helper calls in both `auto` and explicit `providers` modes.
   - `smartProviders` (`smart_card.dart:1084-1088`) and `smartAsk` (`smart_card.dart:2156-2165`) currently take no config-facts collector callback. Like `hub` and `mcpSearch`, `smartAsk` needs an injectable collector callback wired in `packages/maprisma_core/lib/src/plan_worker.dart:1329-1349` (where `identity` and `registry` already exist), emitting `progress?.call('Checking…')` before collecting facts (`plan_worker.dart:1337-1340`; `agent(...)` already emits `'Ask AI'` at `smart_card.dart:2236`).
   - Validate `provider` (`p['configurable'] == true`), `profile`, and `model` (and check `ruleAllows` on `facts['action_rules']` for `ActionCheck('update', 'providers', key)` if denied) **before** collecting facts or making Call 2 so an invalid or denied request never spends Call 2 tokens.
   - Call 2 must never return `status: 'lookup'` (which would trigger a 3rd call in `smartFinish`, `smart_card.dart:2294-2300`), must return `status: 'error'` on `bad_answer` (never `redirect`, which `auto` converts to `status: 'answer'` at `smart_card.dart:2301-2309`), and must return a non-empty `summary` from the real facts/recommender (otherwise `smart_card.dart:2314-2317` falls back to Call 1's pre-facts `decision['summary']`).

5. **Replacing `performance` with `configurable` / `provider_config` affects `core.dart`, `smart_card.dart`, `map_smart_card.dart`, `main.dart`, and 078 tests**
   - `core.dart:3399-3413` (not `3284`) builds `'providers'` for `auto || column == 'providers'`, with `'performance': rt['installed'] == true` at `core.dart:3411`. Replace `'performance'` with `'configurable'` (true only when the provider is installed and has a config schema).
   - `smart_card.dart:1138-1150` (`smartProviders`) checks `p[action] == true` for `'install', 'update', 'start', 'stop', 'performance'`. Remove `'performance'` and handle `action == 'provider_config'` in its own branch checking `p['configurable'] == true` (not `p['provider_config']`).
   - `smart_card.dart:170` (`smartCandidateChecks`) removes `'provider_action' when candidate['step'] == 'performance' => const []` and adds `'provider_config' => [ActionCheck('update', 'providers', '${candidate['key']}')]`. (Note: keeping this uniform matches 077's rule that `models.config_preview` and `provider_config` share the same permission; if an `update` deny rule applies to an advice-only provider, the candidate is also refused.)
   - `smart_card.dart:919` (`smartStepNames`) replaces `'performance': 'Performance'` with `'provider_config': 'Configure for this PC'` (or `'Configuration'`).
   - `packages/maprisma_core/test/smart_card_test.dart:1016, 1093` and `flutter_app/test/smart_window_test.dart:605-690` assert `'performance'` in 078 and must be updated to `'configurable'` / `'provider_config'`.

6. **Review handoff and Configuration page inside the Ask AI overlay (`map_smart_card.dart` & `main.dart`)**
   - 077 (`077-provider-config.md:295`) cites `map_smart_card.dart:2891`. In 078, `_buildProposal` is at `flutter_app/lib/map_smart_card.dart:3394-3554`, the Review button handler at `3495-3525`, and auto-mode effect-specific labels at `3526-3543` (`'Open Performance'` at `3532-3533`).
   - Without updating `map_smart_card.dart:3495-3543`, a `kind: 'provider_config'` candidate falls into the `else` branch `_openReview(proposal, c)` (`3523`) → `map.smart_review` → `Invalid request` (`core.dart:3589`).
   - In 078, Performance opens **inside** the Ask AI overlay (`_SmartStep.performance`, `map_smart_card.dart:529, 582-587, 948-1005, 3867-3882`) via `widget.performancePage` → `main.dart:1894-1925` (`_performancePage`), which currently takes only `(String key, {aside, back})`, rejects `runtime['tunable'] != true` (`main.dart:1900`), and calls `_readTuning(key)`.
   - `performancePage` (or renamed `configPage`) must accept optional prefill `{model?, profile?, values{}, reasons{}, config_proposal}`, check `runtime['configurable'] == true`, load `models.config`, and prefill "your value" with the "from Ask AI" badge (showing the snippet for advice-only providers). In `_aside` (`map_smart_card.dart:985-997`), only reload fresh (dropping prefill) after an actual apply; cancelling the Apply review must return to the Configuration page with the user's prefilled/edited values intact (matching 078's Back/Cancel preservation rule). Also update `_smartProvider` (`main.dart:2400-2408`) for the non-embedded fallback.

7. **Follow-up context (`_responseField`) in 078 is unaccounted for in 077**
   - In 078, auto mode renders `_responseField()` (`"Ask a follow-up…"`) below every proposal (`flutter_app/lib/map_smart_card.dart:3915-3919`, implemented at `2671-2761`).
   - Currently `evidence` (`map_smart_card.dart:2681-2691`) only includes `_prompt.text`, `_lastClarification`, `_reply['summary']`, and `'${c['title']} ${c['reason'] ?? ''}'`. For `provider_config` candidates, follow-ups like `"Why 16k context?"` or `"Use q4_0 instead"` need `key`, `model`, `profile`, and a compact `values` summary included in `evidence` (bounded within 3,000 chars), while **never** putting `config_proposal`, file paths, or secrets into `_previousContext`.
   - Call 2's prompt must also receive `facts['context']` (wrapped via `_request(facts)` / `_data(...)`, `smart_card.dart:79-85`), while always re-collecting fresh hardware/provider facts and re-validating. Explanation follow-ups (`"Why q8_0?"`) can be answered by Call 1 via `{"action": "answer", "summary": "..."}` in 1 call; refinement follow-ups run Call 2 and mint a new `config_proposal`. Helper-switch consent (`map_smart_card.dart:2704-2715`) works automatically as long as `helper` and `local` stay on `_reply`.

8. **Composer, dictation, error forwarding, and shifted line references outside section 6**
   - **Unified composer & starter examples:** Central Ask AI uses `_unifiedComposer` (`map_smart_card.dart:2503-2660`) with `MicButton` (`mic_button.dart`) + `_voiceNotice()` (online dictation notice before recording) and starter example `'Why are answers slow on this PC?'` (`map_smart_card.dart:2596`), plus `onNodeAsk` (`main.dart:6232-6240`). Built-in presets at `map_smart_card.dart:119-129` (`'Why is my local LLM slow?'`, `'Check GPU and context settings'`) remain; remember tests index the first 8 (`map_smart_card.dart:91-92`).
   - **`_invalidRequest` message forwarding:** 077 line 55-56 says validation errors leave the core as bare `invalid_request`. In 078, `_invalidRequest` (`core.dart:5523-5531`) forwards localized `'message'` for allowlisted `FormatException`s, already including `'This proposal has expired'` and `'This helper is not ready'`. Reusing `FormatException('This proposal has expired')` for expired `config_proposal` handles gives localized GUI errors automatically.
   - **`ConnectionReview` gained `busy`:** `flutter_app/lib/connections_view.dart:510-519, 601-608` added `busy` (spinner + disabled Cancel/Apply) in 078; 077 must preserve it when adding the warning tick and restart option.
   - **Shifted line references & base branch:**
     - Base branch (`077-provider-config.md:3-4`): now starts from `task/078-unified-ask-ai` (or `main` after 078), not `task/076-agent-history`.
     - `tuningRoute`: `core.dart:2442` (was `2432`).
     - `Connections.undo`: `packages/maprisma_core/lib/src/core_tasks.dart:413` (was `401`, shifted by `CoreTasks.completed` at `103-112`).
     - Map box speed icon: `flutter_app/lib/main.dart:4321-4330` (was `4237`), gated by `_tunable(node)` (`main.dart:2516-2526`, which must switch to `configurable`).
     - `routes.json:1401`: `map.smart_ask` note must also be updated (and `docs/protocol.md` / `core_client.g.dart` regenerated) to document `provider_config` candidates and `config_proposal`.

---

### 2. Exact replacement text for 077

#### Header (replaces lines 3–6)

```markdown
Author: Codex · Reviewer: Antigravity · Branch: task/077-provider-config
(started from `task/078-unified-ask-ai` / `main` after 078). Plan review
rounds 1–3 are in [reviews/077-provider-config.md](../reviews/077-provider-config.md),
and all findings plus the 078 alignment are taken in below (v5).
```

#### Inventory bullets under `## What exists` (replaces lines 50–74)

```markdown
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
```

#### Section 5 additions/updates (in `### 5. Routes`)

- Add one row to the Routes table (after `providers.snapshot`, line 231):

```markdown
| `map.smart_ask` | read | unchanged (`column`, `command`, `request`, `answer?`, `context?`) | update `routes.json:1401` note to document `provider_config` candidates (`{id, kind, title, subtitle, reason, fit, size, key, model?, profile, values{}, reasons{}, writable, config_proposal}`) alongside 078's `auto`, `context`, `answer` and `sources` |
```

- Replace line 257 (`core_tasks.dart:401` → `core_tasks.dart:413`):

```markdown
  write or restore a `.service` file or drop-in. `connections.undo` runs in
  `core_tasks.dart:413` (`Connections.undo` → `ConfigFiles.undo`), so both
```

#### Section 6 replacement (replaces lines 274–314)

```markdown
### 6. Ask AI

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
```

#### Section 7 updates (lines 317–323, 343–353)

- Replace lines 317–323:

```markdown
- **"Configure for this PC"** (only for configurable providers):
  - the map box's speed icon (`main.dart:4321-4330`, gated by `_tunable` at
    `main.dart:2516-2526` switched to `configurable`) becomes the Configure
    action, also in the box menu (`_addonMenu`);
  - the Providers page (`providers_view.dart:169`);
  - Ask AI's `provider_config` proposals (opened embedded inside Ask AI via
    `performancePage`, `main.dart:1894-1925`).

  It opens the Performance page, renamed **"Configuration"**.
```

- Replace line 343 and line 352–353:

```markdown
  - **Apply:** opens `ConnectionReview` (preserving 078's `busy` state),
    extended with a list of warnings to tick and a post-apply step:
```

```markdown
  - **Ask AI:** helper dropdown and a focus line using the shared `MicButton`
    and online dictation notice (as in 075/078). It fills your value with a
    badge "from Ask AI".
```

#### Acceptance updates (replaces lines 391–397)

```markdown
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
```

### Answer (Claude, 2026-11-19)

All 8 points taken over, with the replacement texts as they are (plan v5). 077 is built on main after 078.

## Code Review Round 1 (Antigravity, 2026-11-19, `task/077-provider-config` working tree)

Read-only review of the current working tree (no files edited, no providers started/stopped/loaded/unloaded/reconfigured, no credentials or Strata presets read). Overall the implementation is solid across the memory model, measured `llama_tune` reserve, `daemon-reload` + Undo preservation, action-rule registration, and provenance handling in `finalizeSmartAsk`. Below are the concrete regressions/bugs found, ordered by severity.

---

### High

#### 1. Owned llama.cpp unit-flag migration injects per-model overrides into every existing `[model]` section, breaking `All models (default)` (`*`) edits
- **Where:** [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L589)
- **Trigger & what goes wrong:**
  When `llama-server.service` is Maprisma-owned and carries `--gpu-layers all --flash-attn on` (as installed prior to 077 and confirmed in Step 0), and `models.ini` already has tuned model sections (e.g., `[Qwen3.8-27B-Q4_K_M]` containing only `ctx-size` / `ubatch-size`), `changes()` loops over `{'*', ...ContextReader.iniSections(old).keys}` and writes `gpu-layers = all` and `flash-attn = on` into **every** existing `[model]` section before applying `values` to `model`.
  - If the user opens **All models (default)** (`*`), changes `gpu-layers` to `20` (or `flash-attn` to `off`), and applies, `[*]` gets `gpu-layers = 20` while every existing `[model]` section gets a newly created `gpu-layers = all` override. Because `llama-server` lets `[model]` override `[*]`, the user's default edit has **no effect** on any existing model section.
  - Even editing an unrelated key on one model pollutes every other model section with permanent `gpu-layers` and `flash-attn` overrides, breaking future inheritance from `[*]`.
- **Fix:**
  Write migrated unit flags into `[*]`, and for non-`*` sections only overwrite `flag.key` when that section already explicitly contained `flag.key` in `old` (preserving dormant per-model keys that were previously shadowed by the unit's CLI flags, while letting models without overrides continue inheriting from `[*]`). Update [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L405) accordingly and add a test covering both a default (`*`) edit of `gpu-layers` with existing model sections and a shadowed per-model override.

> Author (Codex): Fixed: migrate flags into [*] and only already-explicit model keys. Models without overrides inherit new default edits. Added default-edit and shadowed-override regression coverage.

#### 2. Uncaught `read(context.modelsIni)` inside `collect()` crashes `models.config` and `map.smart_ask` on unsafe/symlinked `models.ini`
- **Where:** [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L446)
- **Trigger & what goes wrong:**
  If `~/.config/llama.cpp/models.ini` is a symlink, foreign-owned, group/world-writable (`0666`), or sits in an untrusted parent directory (`0777`), lines [331–352](../../packages/maprisma_core/lib/src/provider_config_files.dart#L331) and [405–420](../../packages/maprisma_core/lib/src/provider_config_files.dart#L405) catch the exception so `collect()` degrades cleanly to `writable: false` with `'Configuration file is unavailable'`. Line [449](../../packages/maprisma_core/lib/src/provider_config_files.dart#L449) then calls `read(context.modelsIni)` outside any `try/catch` to build `'overrides'`, throwing out of `collect()` and crashing both `models.config` and `map.smart_ask` Call 2.
- **Fix:**
  Read `models.ini` once inside a guarded block (or wrap the `'overrides'` read in `try { ... } on Object { ... }` / skip when `!writable`), returning `{}` for `'overrides'` when the file cannot be safely read.

> Author (Codex): Fixed: build overrides in a guarded read and return empty overrides/read-only facts when the preset is unsafe. Added a symlinked-preset collection test; unsafe leaves and ancestors remain refused for writes.

#### 3. `providers.reload_model` does not require `restart == 'model_reload'`, allowing it to stop services on `vllm` / `strata`
- **Where:** [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L727) (calling [provider_ops.dart](../../packages/maprisma_core/lib/src/provider_ops.dart#L370))
- **Trigger & what goes wrong:**
  Calling `providers.reload_model` with `key: 'vllm'` or `key: 'strata'` (both satisfy `configurable(rt.key) == true`) passes validation in `configControl` and invokes `ops.unloadModel(rt, model)`. In `ProviderOps.unloadModel`, providers without a dedicated unload branch fall through to `canControl(rt) ? stop(rt) : ...` (and for Strata, `canControl(rt)` also reads `StrataFacts.lastPreset()`). Thus `providers.reload_model` **stops the running service**, violating [routes.json](../../packages/maprisma_core/protocol/routes.json#L2024) ("without service restart"). Calling it on `service`-restart providers (`llamacpp`, `ollama`) also unloads/reloads a model without restarting the service that reads `models.ini` / `server.env`.
- **Fix:**
  In `configControl` ([provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L728)), require `configSchema(rt.key).first['restart'] == 'model_reload'` for `providers.reload_model` (throwing `FormatException` otherwise). Also gate `providers.restart` against `writer == 'launch_advice'` if Strata is intentionally excluded from `can_control` in `models.config` ([provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L462)).

> Author (Codex): Fixed: reload requires the schema model_reload capability before guard/unload/load, and restart refuses launch_advice. Tests prove llama.cpp, Ollama, vLLM and Strata cannot enter the reload callbacks.

#### 4. Cancelling Apply after switching model or profile restores stale `facts` (both embedded and standalone), and embedded `Measure and tune` never reloads `facts`
- **Where:**
  - [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L75) and [L169-L180](../../flutter_app/lib/provider_config_view.dart#L169)
  - [main.dart](../../flutter_app/lib/main.dart#L1948) (`_performancePage`) and [L2057-L2083](../../flutter_app/lib/main.dart#L2057) (standalone `_performance`)
  - [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart#L993) (`_aside`)
- **Trigger & what goes wrong:**
  1. Open Configuration for `llama.cpp` (embedded inside Ask AI or standalone). Initial `widget.facts` are for `model: '*'`, `profile: 'balanced'`.
  2. Switch the model picker to a concrete model (e.g., `'Qwen'`) or switch the profile chip to `'long_context'`. `_load()` updates local `_facts` and writes `draft['model']` / `draft['profile']`, then the user edits a field and clicks **Apply**, then clicks **Cancel** in `ConnectionReview`.
  3. Because `_close(refocus: false)` (embedded) and `_cardReview` (standalone) unmount `ProviderConfigurationView` and remount it with the original `widget.facts`, `initState()` resets `_facts = widget.facts` (`'*'` / `'balanced'`) while `draft['model']` is `'Qwen'` and `draft['profile']` is `'long_context'`. The page now renders `'Qwen'` selected in the dropdown alongside `'*'`'s `current`, `recommended`, `overrides`, `writable`, and `fit`.
  4. In embedded Ask AI ([main.dart](../../flutter_app/lib/main.dart#L1987)), `onTune` runs `_measureAndTune` without setting `draft['_reload'] = true`, so returning to the embedded Configuration page displays stale `facts` (`untuned` and old measurements are not refreshed, unlike standalone `_performance` at [L2067-L2069](../../flutter_app/lib/main.dart#L2067)).
- **Fix:**
  Store freshly loaded `facts` in `draft['_facts']` inside `_load()` and initialize `_facts = draft['_facts'] as Map<String, dynamic>? ?? widget.facts` in `initState()` (cleared by `_configurationApplied`). In `_performancePage`'s `onTune`, set `draft['_reload'] = true` after `_measureAndTune` completes so returning from tuning reloads fresh measurements.

> Author (Codex): Fixed: retain freshly loaded facts with the draft when review unmounts the view; fresh reads replace the cached view facts. Applied changes clear them. Embedded tuning marks the page for a fresh read. Added profile/draft remount coverage.

#### 5. `map.smart_ask` accepts `web_search: true` on helpers without web research, violating the protocol contract and spending Call 1 tokens
- **Where:** [core.dart](../../packages/maprisma_core/lib/src/core.dart#L3350) (compare [provider_config_routes.dart](../../packages/maprisma_core/lib/src/provider_config_routes.dart#L71) and [routes.json](../../packages/maprisma_core/protocol/routes.json#L1441))
- **Trigger & what goes wrong:**
  Calling `map.smart_ask` with `command: 'local-helper'` (or any helper with `web_search != true`) and `web_search: true` passes [core.dart](../../packages/maprisma_core/lib/src/core.dart#L3350) because it checks only `h['command'] == command`.
  - If Call 1 routes to `provider_config`, Call 1's tokens have already been spent before `smartProviders` ([smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1171)) rejects it.
  - If Call 1 routes to any other action, `web_search: true` on an incapable helper is silently accepted rather than refused ("Unavailable research capability is refused").
- **Fix:**
  Mirror `models.config_ask` at [core.dart](../../packages/maprisma_core/lib/src/core.dart#L3350):
  ```dart
  if (!smartHelpers().any(
    (h) =>
        h['command'] == command &&
        (params['web_search'] != true || h['web_search'] == true),
  )) {
    throw const FormatException('This helper is not ready');
  }
  ```
  Also reset `_configurationWeb = false` in [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart) when the selected helper switches to one with `web_search != true`, matching [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L701).

> Author (Codex): Fixed: refuse unavailable web capability before diagnostics or Call 1, and clear the checkbox when switching to an incapable helper. Added a dispatch regression proving refusal before any job starts.


---

### Medium

#### 6. Clicking Apply on a stale facts cache fails silently in `ProviderConfigurationView`
- **Where:** [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L350) (compare `_validate()` at [L248-L255](../../flutter_app/lib/provider_config_view.dart#L248))
- **Trigger & what goes wrong:**
  Leave the Configuration page open past the 10-minute `configCache` TTL and click **Apply**. `models.config_preview` returns `{'error': 'stale'}` ([provider_config_routes.dart](../../packages/maprisma_core/lib/src/provider_config_routes.dart#L64)). Line [350](../../flutter_app/lib/provider_config_view.dart#L350) sets `_check = preview` and returns without populating `_check['errors']` or `_message`. Because `errors` is empty and `_message` is `''`, no error text or "Read again" button appears; Apply does nothing.
- **Fix:**
  In `_apply()`, check `if (preview['error'] == 'stale')` and set `_message = tr('Read the configuration again before applying.')` plus `_check = {'errors': [{'text': 'Read the configuration again before applying.'}]}` (with a fallback message if `preview['ok'] != true` has no `errors`).

> Author (Codex): Fixed: stale and malformed previews display an actionable error, disable Apply and offer Read again. Added a stale-preview widget test.

#### 7. Central Ask AI web-search `sources` (and `summary`) for `provider_config` are never shown in the UI
- **Where:**
  - [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1200)
  - [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart#L3356) and [L3541-L3545](../../flutter_app/lib/map_smart_card.dart#L3541)
  - [main.dart](../../flutter_app/lib/main.dart#L1900)
- **Trigger & what goes wrong:**
  Enable **Search the web for provider guidance** in central Ask AI and ask to configure a provider. `smartProviders` puts `'sources'` only on the top-level reply (not on candidate `c1`), and candidate `c1` has `'reason'` rather than `'summary'`. In `MapSmartCard`, `_reply['sources']` is rendered only in `_buildRedirect` ([L3356](../../flutter_app/lib/map_smart_card.dart#L3356)), not in `_buildProposal`. When the user clicks **Review configuration**, only `c` is passed as `prefill` ([L3544](../../flutter_app/lib/map_smart_card.dart#L3544)), so `_configurationDraft` ([main.dart](../../flutter_app/lib/main.dart#L1905)) receives neither `'sources'` nor `'summary'`, and the returned HTTPS source links are never displayed anywhere.
- **Fix:**
  Include `'sources': proposal['sources']` and `'summary': proposal['summary']` on the `provider_config` candidate in `smartProviders` (and/or render `_reply['sources']` in `_buildProposal`).

> Author (Codex): Fixed: carry the bounded HTTPS sources and summary on the configuration candidate through the existing prefill. Configuration renders clickable source links. Added candidate-payload assertions.

#### 8. `configProposalSchema` omits `"type"` on `"enum"` and uses `"const"` inside `anyOf`, which strict JSON Schema runners (Codex `--output-schema`) reject
- **Where:** [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L663) (used by `codex --search exec ... --output-schema {schema}` in [codex.toml](../../adapters/codex.toml#L136))
- **Trigger & what goes wrong:**
  Use Codex with **Search the web for guidance** on any provider with `enum` or `int_or_special` keys (llama.cpp, Ollama, Jan, LM Studio, KoboldCpp, vLLM). `configProposalSchema` emits untyped `{"enum": [...]}` and `{"anyOf": [{"type": "integer"}, {"const": ...}]}` (even for integer specials like `-1` / `-2`). OpenAI's strict JSON Schema validator rejects `const` and untyped `enum` nodes, causing Codex web-research calls to fail with `helper_failed`.
  *(Secondary note: [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L2050) writes per-PID `schema-$smartTask-$pid.json` files without cleaning them up in `finally`, leaking files in `~/.cache/maprisma/research/`.)*
- **Fix:**
  Emit explicit `'type': values.every((v) => v is int) ? 'integer' : 'string'` alongside `'enum'`. For `int_or_special`, filter string specials separately: emit plain `{'type': 'integer'}` when all specials are `int`, and `{'anyOf': [{'type': 'integer'}, {'type': 'string', 'enum': stringSpecials}]}` when string specials exist. Delete the temp `schema` file in `smartLookup`'s `finally` block.

> Author (Codex): Fixed: every enum has an explicit type; integer specials use an integer schema and string specials use a typed string enum union. Research schema files are deleted in finally. Tests check the generated schemas and cleanup after a fake helper call.

#### 9. KoboldCpp recommends `gpulayers: 1` when GGUF metadata is missing, and HF `config.json` `head_dim` omits `hf.attention.value_length`
- **Where:**
  - [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L387)
  - [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L260)
- **Trigger & what goes wrong:**
  1. For a KoboldCpp `.kcpps` whose GGUF metadata is unreadable (`blocks == 0`), `totalLayers = math.max(1, blocks + 1) = 1`, `layers = 1`, and line [413](../../packages/maprisma_core/lib/src/provider_config.dart#L413) unconditionally sets `layerValue = layers` (`1`), recommending offloading **only 1 layer** onto the GPU instead of `-1` (auto/all).
  2. For vLLM models whose HF `config.json` sets an explicit `head_dim` differing from `hidden_size ~/ num_attention_heads` (e.g., Gemma 2/3, Qwen3), `hfModel` sets only `'hf.attention.key_length'` and omits `'hf.attention.value_length'`, so `kvLayout` ([context.dart](../../packages/maprisma_core/lib/src/context.dart#L201)) falls back to `hidden_size ~/ num_attention_heads` for V, skewing the KV memory estimate.
- **Fix:**
  - At [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L413): `if (configWriter(facts) == 'kobold_json' && blocks > 0) layerValue = layers;` so unknown-block-count models keep `-1`.
  - At [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L260): set both `'hf.attention.key_length'` and `'hf.attention.value_length'` when `number(['head_dim']) > 0`.

> Author (Codex): Fixed: unknown Kobold layer counts retain auto (-1), and explicit HF head_dim sets both K and V lengths. Added unknown-metadata and HF metadata assertions.


---

### Low

#### 10. Selecting a `special` `ChoiceChip` or clicking "Use the default" on an overridden field leaves stale text in the `TextFormField`
- **Where:** [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L227) and [L510](../../flutter_app/lib/provider_config_view.dart#L510)
- **Trigger & what goes wrong:**
  1. Type `20` into `gpu-layers`, then click the `all` `ChoiceChip`. `_edit(id, 'all')` updates `values` without calling `_syncEditors()`, so `all` shows selected while the text input still displays `20`.
  2. On a llama.cpp model with an explicit `ctx-size` override (e.g. `4096`), click **Use the default**. Line [227](../../flutter_app/lib/provider_config_view.dart#L227) calls `_edit(id, null)` without `_syncEditors()`, leaving `4096` in the text input instead of clearing to the `Default` hint.
- **Fix:**
  Call `_syncEditors()` inside `setState` in `_useDefault` ([L227](../../flutter_app/lib/provider_config_view.dart#L227)) and in `ChoiceChip.onSelected` ([L510](../../flutter_app/lib/provider_config_view.dart#L510)).

> Author (Codex): Fixed: synchronize controllers only after the special/default actions, preserving typing/caret behavior during normal edits. Tests verify the displayed text after all and Use the default.

## Code Review Round 2 (Antigravity, 2026-11-19, `task/077-provider-config` working tree)

Read-only review of `/mnt/Data/Projects/maprisma-codex` on `task/077-provider-config` (no edits, no commits, no credential or Strata preset reads, no provider start/stop/load/unload/reconfiguration).

### Round 1 Verification (10/10 fixed)

1. **Owned `llama.cpp` unit-flag migration:** Fixed in [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L606) (`[*]` plus already-explicit per-model keys only; models without overrides inherit default edits cleanly) and covered in [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L507).
2. **Unsafe `models.ini` overrides read in `collect()`:** Fixed in [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L444) and tested in [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L529).
3. **Reload/restart capability guards:** Fixed in [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L743) (`providers.reload_model` requires schema `restart == 'model_reload'`; `providers.restart` and `collect()`'s `can_control` short-circuit `launch_advice` before `ops.canControl`, avoiding Strata preset reads and unsafe stops), tested in [provider_config_routes_test.dart](../../packages/maprisma_core/test/provider_config_routes_test.dart#L125).
4. **Cancel after scope/profile switch + embedded tune reload:** Fixed in [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L75), [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L170), and [main.dart](../../flutter_app/lib/main.dart#L1923), tested in [provider_config_view_test.dart](../../flutter_app/test/provider_config_view_test.dart#L247).
5. **`map.smart_ask` `web_search: true` on incapable helpers + UI reset:** Fixed in [core.dart](../../packages/maprisma_core/lib/src/core.dart#L3339) (rejected before diagnostics and Call 1) and [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart#L753), tested in [provider_config_routes_test.dart](../../packages/maprisma_core/test/provider_config_routes_test.dart#L248).
6. **Stale preview handling:** Fixed in [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L352), tested in [provider_config_view_test.dart](../../flutter_app/test/provider_config_view_test.dart#L274).
7. **Central AI `summary`/`sources` handoff:** Fixed end-to-end across [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1211), [main.dart](../../flutter_app/lib/main.dart#L1896), and [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L795), tested in [provider_config_routes_test.dart](../../packages/maprisma_core/test/provider_config_routes_test.dart#L441).
8. **Typed JSON schemas + temp schema file cleanup:** Fixed in [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L677) and [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L2096), tested in [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L88) and [L904-L909](../../packages/maprisma_core/test/provider_config_test.dart#L904).
9. **KoboldCpp unknown layers `-1` + HF `head_dim` K/V lengths:** Fixed in [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L421) and [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L266), tested in [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L216) and [provider_config_routes_test.dart](../../packages/maprisma_core/test/provider_config_routes_test.dart#L120).
10. **Editor controller sync on `special` chip and `Use the default`:** Fixed in [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L218) and [L528-L533](../../flutter_app/lib/provider_config_view.dart#L528), tested in [provider_config_view_test.dart](../../flutter_app/test/provider_config_view_test.dart#L221).

*Additional checked fixes verified:* numeric recommendation clamping & measured batch compatibility ([provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L326), [L492-L506](../../packages/maprisma_core/lib/src/provider_config.dart#L492)) and app-server PID write ordering ([test_agent_details.py](../../tests/test_agent_details.py#L104)) are clean. However, the new global-engine `model == ''` selector change introduces two regressions below, plus one minor i18n omission.

---

### Remaining Actionable Findings

#### 1. High — Global engines (`ollama`, `vllm`, `strata`) selecting `model == ''` break `displayCurrent`, `configModel`, sizing/clamping, and vLLM fit
- **Where:**
  - [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L17) (`configModel`)
  - [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L47) (`current` / `displayCurrent`)
  - [provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L49) (`select`) and [L411-L429](../../packages/maprisma_core/lib/src/provider_config_files.dart#L411) (`collect`)
- **Trigger & what goes wrong:**
  `ProviderConfigFiles.select()` now returns `''` for every `scope == 'global'` provider (`ollama`, `vllm`, `strata`), while `collect()` stores global readings under `settings['*']` and `configured['*']`. When `models.config`, `models.config_check`, `models.config_preview`, or `models.config_ask` constructs `ConfigMath(facts, '')`:
  1. **Every configured Ollama setting displays as `null` (`Engine default`):** `current` looks up `(facts['settings'] as Map?)?['']`, which is `{}`. Even though `displayCurrent` falls back to `configured['*']` at line 55, line 60 reads `current[field['id']]` from `{}` and returns `null` for every key present in `~/.config/ollama/server.env` (both in the Configuration UI and in `configPrompt`'s `current`).
  2. **`configModel(facts, '')` returns `{}` instead of the largest model:** Line 19 checks `if (model != '*')` (true for `''`), fails to find a model named `''`, and returns `{}` (`meta = {}`, `blocks = 0`, `trained = 0`, `size = 0`).
     - On **Ollama**, `recommend()` never clamps `OLLAMA_CONTEXT_LENGTH` to `trained` ([L476](../../packages/maprisma_core/lib/src/provider_config.dart#L476)) and never falls back to CPU/RAM when weights exceed VRAM ([L394-L413](../../packages/maprisma_core/lib/src/provider_config.dart#L394) sees `weights == 0`). `validate()` never warns when context exceeds `trained` ([L268](../../packages/maprisma_core/lib/src/provider_config.dart#L268)) and *always* emits `'Model memory is not fully known; this is an estimate'` ([L305](../../packages/maprisma_core/lib/src/provider_config.dart#L305)), forcing the warning-ack checkbox on every Ollama apply even with complete GGUF metadata.
     - On **vLLM** (`perSlot == false`), `fitModels()` returns `[target]` (`[{}]`), so `fit()` reports `weights: 0, kv: 0` and ignores the HF `config.json` and `.safetensors` sizes collected by `hfModel()`.
  *(Existing tests missed this because [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L212), [L226](../../packages/maprisma_core/test/provider_config_test.dart#L226), [L341](../../packages/maprisma_core/test/provider_config_test.dart#L341), and [L359](../../packages/maprisma_core/test/provider_config_test.dart#L359) pass `'*'` or `'model'` into `ConfigMath` instead of `''`, and [provider_config_fixture.dart](../../flutter_app/test/support/provider_config_fixture.dart#L5) still uses `model = '*'` / `scope_models: ['*']`.)*
- **Fix:**
  - In `configModel(facts, model)` ([provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L19)): change `if (model != '*')` to `if (model != '*' && model.isNotEmpty)`. (Empty `per_model` providers have `models == []`, so `sorted.firstOrNull ?? const {}` still returns `{}`.)
  - In `ConfigMath.current` ([provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L47)): fall back to `(facts['settings'] as Map?)?['*']` when `schema.first['scope'] == 'global'` (or key `settings['']` for global scope in `collect()`).
  - Add end-to-end `collect()` → `select(facts, null)` (`''`) → `view(facts, '', 'balanced')` tests for Ollama (verifying non-null `current` from `server.env`, `trained` context clamp, and no false unknown-memory warning) and vLLM (verifying non-zero HF `weights`/`kv` in `fit`).

> Author (Codex): Fixed: global current values use settings[*], and the empty global selector chooses the largest sizing model. Added collect/select/view tests with a real GGUF fixture for Ollama and HF metadata/weights for vLLM, verifying trained-context clamps, current values and non-zero memory estimates. The UI fixture now uses the real empty global selector.

#### 2. Medium — `smartProviders` early validation mismatches global-scope `model` rules, running full `collect()` before `select()` throws
- **Where:** [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1154) (with [core.dart](../../packages/maprisma_core/lib/src/core.dart#L3450) and [plan_worker.dart](../../packages/maprisma_core/lib/src/plan_worker.dart#L1519))
- **Trigger & what goes wrong:**
  For `config_scope == 'global'` (`ollama`, `vllm`, `strata`), [core.dart](../../packages/maprisma_core/lib/src/core.dart#L3450) passes `'models': rt['models']` and `'config_scope': 'global'` into Call 1. In `smartProviders`, early validation only checks `model == '*' && provider['config_scope'] == 'per_model'` and `model != '*' && !models.contains(model)`:
  - If Call 1 outputs `{"action": "provider_config", "provider": "ollama", "model": "*"}` or names an installed Ollama model (e.g. `"model": "qwen2.5:7b"`), early validation passes, `configFacts` executes the full `store.collect(rt)` hardware/GGUF scan, and `store.select(collected, model)` ([plan_worker.dart](../../packages/maprisma_core/lib/src/plan_worker.dart#L1519)) then throws `FormatException('This provider has global settings')`.
  - Conversely, if Call 1 outputs `"model": ""` for a global provider, `smartProviders` rejects it before `configFacts` even though `store.select()` accepts `''`.
- **Fix:**
  In [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1154), branch on `provider['config_scope'] == 'global'` so only `model == null || model == ''` is accepted before `configFacts` (and reject non-empty strings / `'*'` early without running `collect()`). Add a unit test covering `model: '*'`, `model: 'model'`, and `model: ''` on a `global` provider in `smartProviders`.

> Author (Codex): Fixed: global selectors accept null/empty only before collecting any facts; invalid concrete/default choices return after Call 1. Both prompts explicitly tell the helper to omit a global model. Tests cover *, an installed name and empty, including collection/call counts.

#### 3. Low — Central Ask AI `provider_config` card subtitle `'Configure for this PC'` is not localized
- **Where:** [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart#L3504) (paired with [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1209))
- **Trigger & what goes wrong:**
  `smartProviders` sets `'subtitle': 'Configure for this PC'` (a key present in all 7 `translations/*.json` files) on `provider_config` candidates, but `_buildProposal` only wraps `c['subtitle']` in `widget.tr(...)` for `agent_action`, `provider_action`, and `menu_action`. In non-English locales, the central Ask AI proposal card renders the untranslated English string `'Configure for this PC'`.
- **Fix:**
  Include `c['kind'] == 'provider_config'` in the `widget.tr(...)` condition at [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart#L3504).

> Author (Codex): Fixed: provider_config subtitles use tr() like the other app-defined captions. A widget test uses a translated caption and verifies the English source caption is absent.

## Code Review Round 3 (Antigravity, 2026-11-19, `task/077-provider-config` working tree)

**CLEAN**

Read-only verification of `/mnt/Data/Projects/maprisma-codex` on `task/077-provider-config` (no edits or commits, no credential or Strata preset reads, no provider start/stop/load/unload/reconfiguration). All three Round 2 findings are fixed cleanly with regression coverage and no regressions to `default`, `per_model`, or safety flows.

### Round 2 Findings Verified

1. **Global engines (`ollama`, `vllm`, `strata`) with `model == ''` — Fixed**
   - [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L17): `configModel` now checks `model != '*' && model.isNotEmpty`, selecting the largest sizing model for empty global selectors while preserving exact-name matching for concrete models and `{}` for empty `per_model` lists.
   - [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L47): `ConfigMath.current` reads `settings['*']` when `schema.first['scope'] == 'global'`, aligning with `displayCurrent`'s `configured['*']` fallback and `collect()`'s storage ([provider_config_files.dart](../../packages/maprisma_core/lib/src/provider_config_files.dart#L411)). Verified end-to-end across `view()`, `validate()`, `recommend()`, `fit()`, `canWrite()`, `_configAgentContexts()`, and [provider_config_view.dart](../../flutter_app/lib/provider_config_view.dart#L869).
   - Tests: real `collect()` → `select(facts, null)` (`''`) → `view()` tests added for Ollama (manifest + GGUF blob verifying non-null `server.env` `current`, `trained` clamp, and absence of false unknown-memory warning) and vLLM (HF `config.json` + safetensors index verifying non-zero `weights`/`kv` and `trained`) in [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L627). UI fixture [provider_config_fixture.dart](../../flutter_app/test/support/provider_config_fixture.dart#L8) and [L57-L59](../../flutter_app/test/support/provider_config_fixture.dart#L57) now use canonical `model = ''` and `scope_models = []` for global providers.

2. **`smartProviders` early validation and prompts for `config_scope == 'global'` — Fixed**
   - [smart_card.dart](../../packages/maprisma_core/lib/src/smart_card.dart#L1152): Branches on `provider['config_scope'] == 'global'` before `configFacts`, allowing only `null` or `''` and rejecting `'*'` or concrete model names after Call 1 with 0 collections, while keeping `default` and `per_model` validation intact.
   - Both [smartProvidersPrompt](../../packages/maprisma_core/lib/src/smart_card.dart#L1070) and [smartAutoPrompt](../../packages/maprisma_core/lib/src/smart_card.dart#L2247) explicitly instruct helpers to omit `model` for `config_scope global` and use `*` only for `default`.
   - Test: [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L939) covers `'*'`, `'model'`, and `''` on a global provider, asserting `calls` (`1`/`1`/`2`), `collects` (`0`/`0`/`1`), and `status` (`error`/`error`/`proposal`).

3. **Localized `provider_config` card subtitle in central Ask AI — Fixed**
   - [map_smart_card.dart](../../flutter_app/lib/map_smart_card.dart#L3503): Includes `c['kind'] == 'provider_config'` in the `widget.tr(...)` branch; `'Configure for this PC'` is present in all 7 `translations/*.json` files.
   - Test: [smart_window_test.dart](../../flutter_app/test/smart_window_test.dart#L681) verifies custom translation rendering and absence of the English source subtitle.

*(Note: Dart/Flutter SDK binaries are not on `PATH` inside this read-only review sandbox, so verification was performed by direct source inspection alongside the author's reported test results.)*

### Validation of the frozen implementation (Codex, 2026-11-19)

`tools/test-changed --base main`, with DISPLAY unset and the Flutter SDK on
PATH, passed formatting, both analyzers, **460 core tests**, **388 Flutter
tests**, **69 differential cases**, and the AOT release transport check.
The native Python run executed **1,441 tests**, with exactly the same seven
historical parity failures documented in tasks 075/076: four failures and
three errors. The command therefore returns non-zero; it is not described
as green. The standing user permission for commits with documented baseline
failures applies to these same seven methods:

- `test_dart_addons_parity.test_same_add_ons`
- `test_dart_setup_guide_parity.test_same_setup_and_guide`
- `test_dart_system_actions_parity.test_same_actions`
- `test_dart_system_moves_parity.test_same_moves`
- `test_dart_installers_parity.test_same_previews_and_installs`
- `test_dart_model_files_parity.test_same_imports_and_pulls`
- `test_dart_model_removals_parity.test_same_removals`

The standard-shell Python suite passes: **1,441 tests, OK (52 native-Dart
parity tests skipped)**. Type checking reports **0 errors, 0 warnings,
0 information diagnostics**. Protocol/manual/translation checks pass,
**14 tests (one native probe skipped)**. Focused configuration checks pass,
**34 core tests and 31 widget tests**. A pre-existing race in the fake Codex
app-server fixture was made deterministic by writing its PID before
publishing the response; its complete module passes **28 tests**.

The fresh isolated Devel release builds successfully and the bundle check
finds no Python. Six off-screen light/dark captures use the real TaskHost
with private provider fixtures and loaded fonts; the files are outside
commits in `.flutter-previews/077-provider-config-shots/`. No installed
provider was started, stopped, reconfigured, loaded or unloaded.

## Code review round 4 — focused parallel inheritance (Antigravity, 2026-11-19)

A post-review edge-case check found that removing a parallel override could inherit an unknown automatic count while updating agent limits. The additional guard was reviewed separately.

### Focused Findings

#### 1. False rejection when clearing a non-positive per-model `parallel` override (`parallel: null`) together with a `context` edit while inheriting a known positive default
- **Location:** [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L244)
- **Trigger:** An `ini_defaults` model currently has an automatic/non-positive per-model override (e.g. `configured['model'] = ['ctx-size', 'parallel']`, `settings['model'] = {'ctx-size': 8192, 'parallel': 0}`), while the inherited `[*]` default is known and positive (`configured['*'] = ['parallel']`, `defaults['parallel'] = 2`). The user submits `{'parallel': null, 'ctx-size': 16384}` to remove the `parallel = 0` override (inheriting `2`) and update context in one save.
- **What goes wrong:** `effective(input)['parallel']` resolves to the known positive inherited default `2` and `unknownInheritance` is `false`, yet the first disjunct `contextEdited && !knownCurrent && !positiveInput` evaluates to `true` and rejects the edit (`knownCurrent` checks the old `current['parallel']` of `0` that is being removed, and `positiveInput` is `false` for `null`). By contrast, `{'parallel': null}` alone is accepted in the exact same state, and `{'parallel': null, 'ctx-size': 16384}` is accepted if the old per-model override happened to be `1` instead of `0`.
- **Suggested fix:** Check whether the *resulting* `parallel` value is known and positive rather than requiring `knownCurrent` when `parallelEdited && input[parallel] == null`:
  ```dart
  final knownInherited =
      (configured['*'] as List? ?? const []).contains(parallel) &&
      configInt((facts['defaults'] as Map?)?[parallel]) > 0;
  final knownResult = parallelEdited
      ? (input[parallel] == null ? knownInherited : positiveInput)
      : knownCurrent;
  if ((contextEdited || parallelEdited) &&
      (!knownResult || configInt(v[parallel]) <= 0)) {
    error(
      parallel,
      'Choose a parallel request count when changing context.',
    );
  }
  ```
- **Test gap:** [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L48) only checks `{'parallel': null}` when `defaults['parallel'] == 2` and keeps `settings['model']['parallel'] == 1`. Adding cases for:
  1. `{'parallel': null, 'ctx-size': 16384}` with `settings['model']['parallel'] == 0` and `defaults['parallel'] == 2` (should pass), and
  2. `{'parallel': null}` when `'*'` omits `'parallel'` from `configured['*']` while `defaults['parallel']` still holds the schema fallback `1` (should fail)
  would cover both inheritance boundaries.

### Verified No Regressions
- **Positive explicit input (`{'ctx-size': 16384, 'parallel': 1}` / `{'parallel': 2}`):** Allowed for both `ini_defaults` and `jan_pair`.
- **Known positive `current[parallel]` (per-model, inherited from `[*]`, or `model == '*'`):** `{'ctx-size': 16384}` allowed; `{'parallel': null}` on `model == '*'` or `jan_pair` (`scope: 'per_model'`) remains rejected earlier at lines 207–222.
- **Unknown/non-positive inheritance (`defaults['parallel'] <= 0` or `'parallel'` absent from `configured['*']`):** Both `{'parallel': null}` and `{'parallel': null, 'ctx-size': 16384}` are rejected, preventing `_configAgentContexts` from dividing by a guessed `1`.
- **Unrelated edits on existing automatic/unknown configurations (e.g. `{'threads': 4}`):** `contextEdited` and `parallelEdited` are both `false`, so unrelated edits remain allowed.

> Author (Codex): Fixed the false rejection by checking the resulting count: explicit positive input, a known positive inherited default, or an unchanged known positive current value. Added simultaneous context edits with old automatic counts 0 and -1 inheriting default 2, plus the absent-default boundary. Unknown automatic inheritance is refused; unrelated edits are allowed.

## Code review round 5 — parallel inheritance verified (Antigravity, 2026-11-19)

**CLEAN**

Focused read-only verification of Code Review Round 4 on `task/077-provider-config` in `/mnt/Data/Projects/maprisma-codex` (no edits, commits, credential/preset reads, external repo/worktree access, or provider actions).

### Round 4 Finding Verified
- **Guard logic — Fixed:** [provider_config.dart](../../packages/maprisma_core/lib/src/provider_config.dart#L237) computes `knownInherited` (`configured['*']` contains `parallel` and `defaults[parallel] > 0`) and `knownResult` (`input[parallel] == null ? knownInherited : positiveInput` when `parallelEdited`, else `knownCurrent`), refusing only when `(contextEdited || parallelEdited) && (!knownResult || configInt(v[parallel]) <= 0)`.
  - Clearing a non-positive per-model `parallel` override (`0` / `-1`) alongside a `ctx-size` edit now succeeds when inheriting a known positive `[*]` default.
  - Inheriting a non-positive `[*]` default (`0`) or an unconfigured `[*]` default (absent from `configured['*']` despite schema fallback `1`) is still refused.
  - Explicit positive `parallel`, unchanged known positive `current[parallel]`, and unrelated edits (neither `contextEdited` nor `parallelEdited`) have no regressions.
- **Test coverage — Verified:** [provider_config_test.dart](../../packages/maprisma_core/test/provider_config_test.dart#L28) exercises unknown current slots (refused), explicit `parallel: 1` (accepted), inherited `0` with and without `ctx-size` (refused), old per-model `parallel` `0` and `-1` with simultaneous `{'parallel': null, 'ctx-size': 16384}` inheriting `2` (accepted), and `configured['*']` omitting `'parallel'` despite `defaults['parallel'] == 1` (refused).
- **Review record checked:** [077-provider-config.md](../../docs/reviews/077-provider-config.md#L727).

### Ordered commit checks

- `14997a8` — protocol. The complete frozen-tree gate above passed all Dart,
  widget, differential and release checks, with only the seven authorized
  native-Python baseline failures.
- `79da872` — core. The full changed-tree run again reproduced only those
  same seven baseline failures. After the final inheritance fix, a fresh
  `tools/test-changed --files` run for the changed validator and regression
  test is **green: 460 core tests, 107 Flutter tests, 10 Python checks**,
  with clean formatting and analyzers. Code round 5 verifies that last fix.
- GUI — the full changed-tree gate passes **460 core tests, 388 Flutter
  tests, 69 differential cases and AOT transport checks**. The native Python
  run again has exactly the same **seven historical baseline failures** and
  no additional failing methods. Screenshot captures pass all six cases.

## Code review round 1 (independent)

Antigravity's independent review, with the majors checked by Uwe. Implementation
consultations were split between Antigravity (core, including the installed
llama.cpp cache layout) and Claude (Configuration UI and widget regressions).
These consultations are not CLEAN verdicts. No live provider was controlled or
reconfigured; tests use private homes, process fixtures and injected effects.

### Major findings

1. **Restart/reload misses connected running agents** —
   `provider_config_files.dart:configControl`, `plan_worker.dart`.
   The guard now receives configured connections and the inventory's connected
   and active agents, including enabled adapter facts. The worker collects the
   inventory without remembering it or calling the map's watcher callback.
   Four regressions exercise the default guard for restart/reload with CPU-only
   and idle-GPU process fixtures: refusal precedes every injected effect, and
   removing the agent process allows the operation.

2. **Impossible partial GPU offload was only a warning** —
   `provider_config.dart:validate`, `context.dart:kvLayout`.
   GPU-resident weights plus verified GPU KV plus the single reserve are now a
   hard limit even for partial offload. The speed warning remains. For the
   verified llama.cpp b12078 build, cache follows the actual repeating layers:
   `ngl = 1` offloads only the output, and `ngl = n` caches the last `n-1`
   repeating layers. Per-layer KV heads and sliding-window fixed terms are
   summed, not averaged. Unknown builds show the full cache as an explicitly
   labelled upper bound; weights plus reserve alone can still prove an error,
   but an uncertain cache upper bound does not cause a false refusal.
   Regressions cover the reported 8/10 GiB case, a cache-driven overflow with
   otherwise fitting weights, a fitting partial configuration, output-only
   placement, heterogeneous/SWA layers and the unknown-placement boundary.
   Task §3 and §4 describe these refined rules. This assumes normal KV offload;
   foreign flags such as `--no-kv-offload` are outside this task's schema.

3. **vLLM recommendations invented CPU/partial offload** —
   `provider_config.dart:recommend`.
   Offload selection is restricted to engines with a GPU-layer key, GPU ratio,
   or Ollama's per-slot runtime. vLLM retains full GPU residency and uses
   `min(vram_available, utilization * vram_total)` throughout context sizing and
   fit. An oversized model says “Model too large for this GPU” and validation
   refuses it; lack of a GPU is also an error. Regressions cover over-commit,
   no GPU and fitting recommendations for all four profiles.

4. **Unwritable file providers received `strata launch` advice** —
   `provider_config_files.dart:snippet`, `provider_config_routes.dart`.
   Only environment, command-advice and launch-advice writers return snippets.
   File writers return null and `config_check` omits the field. Pure and cached
   route tests cover llama.cpp, Jan, LM Studio and KoboldCpp without scanning or
   changing an installed provider.

5. **A deleted draft model prevents reopening Configuration** —
   `main.dart:_readConfiguration` clears the stale model, edited values,
   provenance, summary, reasons and sources, then retries exactly once without
   the model. It handles both a failed read and a successful response whose
   model list omits the saved selection. Profile and source-proposal tracking
   survive, so the stale proposal is not copied back in. Two app widget cases
   close/reopen around deletion or an unlisted response, check the one default
   retry and cleaned draft, then reopen again without the stale request.

### Minor findings

6. **Missing agent-context and Hermes acceptance coverage** —
   `provider_config_contexts_test.dart` adds eight cases against preview plans:
   every model gets the effective per-slot context, Ollama's context stays per
   slot, explicit per-model context/parallel overrides survive a `*` edit, and
   threads/batch edits produce no agent differences. Parallel-only Ollama edits
   also no longer rewrite unrelated agent settings. Hermes retains both a
   nonempty and an empty default model during context-only edits; the YAML
   matcher now uses horizontal whitespace so an empty value cannot consume the
   next line. No preview is applied.

7. **Stale Ask AI, model filtering and empty model selection** —
   (a) `provider_config_view.dart` shows “Read the configuration again before
   applying.” for immediate and task-result stale errors. It cancels pending
   validation and disables Apply until Read again; both response shapes have
   widget regressions. (b) Call 1 now uses exactly
   `chatModels(...).take(40)`, matching collection. A fake private worker captures
   the actual request; the old implementation sends 47 names, including two
   non-chat models, and the regression fails. (c) An empty model from the helper
   is treated as omitted in non-global scopes; two-call default selection is
   tested for llama.cpp and Jan.

8. **Measure and tune borrows unrelated global Undo** —
   `_connectionPreview` passes its own apply result's Undo token explicitly to
   the Configuration draft. `_configurationApplied` no longer reads global
   `_connectionUndo`. App widget tests verify own Apply/Undo and that returning
   from Measure and tune does not attach `undo-tuned` to Configuration. The
   latter fails against the original source. The split follow-up review below
   found that the existing tune reload also discarded cancelled drafts; that
   requires a separate preservation fix in both flows.

9. **Empty research argv advertises web search** —
   `smartHasResearch` requires a nonempty list and is used by both helper
   catalogs and the worker's config-research path. Tests pin catalog refusal
   and prove a direct worker request returns `no_helper`, without collecting
   facts or making a second call. The worker test fails with the old null
   assertion path. A widget regression also checks that switching from a web
   helper to a local helper clears and disables web search and sends false.

### Nits

10. **INI boundary, system Ollama, numeric precision, checking state** —
    (a) Inserting after an unterminated section header first adds the newline;
    deleting from an empty file returns empty text. Both are regression tested.
    (b) Advice-only system Ollama skips anchored app-env reads and reports no
    fictitious unreadable file; the missing-env fixture verifies this without
    creating a file. (c) Utilization and GPU ratio are floored to hundredths
    before use in recommendations, JSON and snippets. The 23/33 utilization
    regression expects 0.69; the ratio regression checks the partial case.
    (d) `_validate` sets checking state through `setState` after initialization;
    initialization uses its explicit no-rebuild path. A widget test checks
    Apply immediately after typing and stepping, before the debounce expires.
    This is defensive coverage: every current caller already rebuilt in the
    same synchronous turn, so that assertion passed before the requested
    state-notification fix. It is not claimed as a reproduced regression.

11. **Misleading build strip and misplaced special-value chip** —
    (a) Build is shown only for llama.cpp with a known value, with readable
    backend names. Widgets deliberately give vLLM and Ollama a foreign build
    and check it is hidden, while llama.cpp shows Vulkan. (b) Special-value
    chips share the editor row beside its field. Geometry regressions cover
    the `all` chip at normal and narrow widths; other special values use the
    same layout. Both old layouts fail the corresponding assertions.

### Validation and review follow-up

Core regressions were run before and after their corresponding fixes. The
new acceptance cases also exposed the Ollama parallel-only rewrite and Hermes
empty-value matcher defects. Logs are kept outside Git under
`/tmp/maprisma-077-independent-*.log`. Final check counts, ordered commits and
the independent follow-up reviews will be appended after verification.

The first full native-Python run of these fixes executed **1,441 tests** in
371 seconds and reproduced exactly the same **four failures and three errors**
listed in the original implementation's validation above, with no additional
failing methods. The standard-shell run is **1,441 OK (52 skipped)**, and type
checking reports **0 errors, 0 warnings and 0 information diagnostics**. The
standing baseline-failure exception applies; native-Python gates are not called
green.

The core fix commit is `16e7050`. Its staged-files `tools/test-changed` run
passes formatting, both analyzers, **491 core tests** and **120 Flutter tests**.
Its 16 selected Python checks contain only the two already authorized baseline
errors (`test_dart_installers_parity` and `test_dart_model_removals_parity`).
The six updated light/dark captures pass and are outside commits in
`.flutter-previews/077-code-round-1-shots/`; the llama.cpp chip now shares the
field row, and Ollama/vLLM show no foreign build label.

Before the GUI fix commit, plain `tools/test-changed` passes both analyzers,
formatting, **491 core tests**, **401 Flutter tests**, **69 differential cases**
and the AOT transport check. Its **1,441 native Python tests** reproduce only
the same **four failures and three errors** above. Generated service translation
tables are included with the seven catalogs; all eight manual editions are
updated. There are **44 additional Dart test cases** compared with the original
460-core/388-widget implementation. DISPLAY was unset for every headless run.

### Split follow-up review (Antigravity and Claude, 2026-11-20)

The first `tools/test-changed --base main` run of the committed fixes again
passes **491 core**, **401 Flutter**, **69 differential cases**, AOT transport
and both analyzers. Its **1,441 native Python tests** reproduce exactly the
seven authorized baseline failures, with no additional failing methods. The
separate final standard-shell Python run is **1,441 OK (52 skipped)** and
typecheck is **0 errors, 0 warnings, 0 information diagnostics**.

Both CLI reviewers inspected the committed source read-only, after that gate.
Their first follow-up was **not CLEAN**. No reviewer ran tests, edited files,
read credentials/presets or controlled a provider. Complete outputs are outside
Git: `/tmp/maprisma-077-independent-agy-verify.md` and
`/tmp/maprisma-077-independent-claude-verify.md`.

1. **Medium, Antigravity — Strata incorrectly classified as GPU only**
   (`provider_config.dart:43`). The GPU-only predicate now requires the GPU
   budget role, rather than any context field without offload. An advice-only
   launch schema does not select a GPU fit basis or GPU context budget. Two
   regressions fail before the fix on CPU-only and 512 MiB GPU fixtures, and
   verify RAM estimation, error-free empty-value advice, preserved
   `strata launch` from `config_check`, and no false too-large-GPU reason.

2. **Major, Claude — cancelling/refusing/failing Measure and tune loses the
   draft** (`main.dart:2037,2120`, `provider_config_view.dart:152`). The earlier
   preservation claim was incorrect: `_reload = true` re-entered `_load`,
   which cleared the draft even without a tune apply. `_measureAndTune` now
   returns whether its review actually applied. An unapplied embedded tune
   requests a facts-only reload which keeps values, provenance, reasons,
   summary, sources, `_source_proposal` and own Undo. The standalone flow also
   re-reads facts without clearing that draft. Applied tunes reset as before.
   Six app widget regressions fail before the fix: cancelled, refused and
   failed tunes in both flows. They check all the preserved draft fields.

3. **Minor, Claude — refused or failed transport starts destroy a saved draft**
   (`main.dart:1945`). A `BackendError` before the configuration task starts
   must be rethrown while preserving the draft. Failed model-read tasks and
   unlisted models still get the one clean default retry. The catch now
   explicitly rethrows `BackendError` and only falls back for the specific
   failed `models.config` task state. A busy-start widget regression fails
   before the fix (two requests and lost draft), then verifies the first
   refusal makes one request and a later reopen preserves the complete draft.

4. **Nit, Claude — reload fallback leaves web checked for a local helper**
   (`provider_config_view.dart:177`). Reload must clear the web choice when the
   selected helper loses research capability. `_load` now clears the web choice
   after selecting the fallback helper. A widget regression first enables web
   on the online helper, then reloads with only a local helper and checks that
   the disabled checkbox is unticked. It fails against the old implementation.

All **eight additional GUI regressions** were reproduced before their fixes;
the focused follow-up run passes **14 widget cases**, with a clean analyzer.
The Strata follow-up's focused core/route run passes **59 cases**. Follow-up
logs are `/tmp/maprisma-077-gui-followup-{red,green,analyze}.log` and
`/tmp/maprisma-077-independent-strata-{red,green}.log`, outside Git.

The follow-up core commit's staged-files `tools/test-changed` run is fully
**green: 493 core tests, 128 selected widget tests and 10 Python checks**, with
clean formatting and analyzers. This run includes the new Strata regressions
and all eight new GUI regressions.

That core follow-up is committed as `ce3eaf7`. The follow-up GUI commit's plain
`tools/test-changed` is also fully **green: 118 selected widget tests and eight
Python protocol checks**, with clean formatting and analyzer. Fresh captures
from the follow-up source pass all six cases in the same private screenshot
directory. A new full branch gate and focused re-review follow these commits.

### Follow-up verification, 2026-11-20

The new full `tools/test-changed --base main` run passes **493 core tests**,
**409 Flutter tests**, **69 differential cases**, AOT transport, formatting and
both analyzers. Native Python runs **1,441 tests** with exactly the same seven
authorized baseline failures (four failures, three errors). The final
standard-shell Python run is **1,441 OK (52 skipped)**; typecheck again reports
**0 errors, 0 warnings, 0 information diagnostics**. All runs are headless.

**Antigravity: CLEAN for the assigned core follow-up scope.** The reviewer
checked all seven schemas, GPU placement, context sizing, Strata's empty-value
advice and snippets, the new regressions, and that vLLM and all five offloading
providers retain their previous branches. This is read-only source inspection;
the reviewer ran no tests, builds, provider operations or credential/preset
reads. Full output: `/tmp/maprisma-077-independent-agy-followup-verify.md`.

**Claude: all three GUI follow-ups verified; one remaining nit.** Cancelled,
refused and failed tunes preserve drafts in both flows, busy/transport starts
do not destroy them, and helper fallback clears web selection. The reviewer
found that `_configurationApplied` also cleared `_source_proposal`, so returning
from an applied embedded tune and reopening the same Ask AI candidate copied
the old proposal back over the newly tuned state. The same stale prefill could
reappear after other apply/Undo paths. Correction and regression are recorded
below. Full read-only output:
`/tmp/maprisma-077-independent-claude-followup-verify.md`.

The final nit is fixed by retaining `_source_proposal` alongside model and
profile in `_configurationApplied`. Actual proposal values, provenance and
Undo are still cleared after an applied tune; the retained private marker
prevents copying the same consumed prefill again. A new app widget regression
first failed with restored `{'mode': 'b'}`. It now applies an embedded tune,
returns to Ask AI, reopens the same candidate and verifies a fresh facts read,
empty edited values, no old handle or “From Ask AI” label, and no unrelated
tune Undo. The focused **nine widget cases pass**, with a clean analyzer.
Evidence: `/tmp/maprisma-077-gui-source-proposal-{red,green,analyze}.log`.

The final nit's plain `tools/test-changed` run is fully **green: 92 selected
widget tests and eight Python protocol checks**, with clean formatting and
analyzer. It is included in the existing GUI follow-up commit; the next full
branch run covers the amended source before Claude's final verification.

### Final code review — CLEAN (2026-11-20)

**Antigravity core: CLEAN. Claude GUI: CLEAN.** All eleven independent round-1
findings and the five issues found during the split follow-ups are addressed.
Antigravity's core source remains unchanged since its CLEAN verification.
Claude's final read-only review confirms the consumed-source marker fix,
successful config/Undo/tune callers, preservation on unapplied tunes, fresh
proposal replacement and the new real-app regression. Full final GUI output:
`/tmp/maprisma-077-independent-claude-final-nit-verify.md`. Neither reviewer ran
tests or controlled providers; these are source-inspection verdicts.

Final verification on the amended source, with DISPLAY unset:

- `tools/test-changed --base main`: formatting and both analyzers clean;
  **493 core tests**, **410 Flutter tests**, **69 differential cases** and AOT
  transport pass. The **1,441 native Python tests** reproduce exactly the
  seven authorized baseline methods listed above: **four failures and three
  errors**, with no new failing methods. That command is not called green.
- Standard-shell Python: **1,441 tests, OK (52 native-Dart checks skipped)**.
  `UV_OFFLINE=1 tools/typecheck.sh`: **0 errors, 0 warnings, 0 information
  diagnostics**.
- **55 additional Dart test cases** over the original 460-core/388-widget
  implementation: 33 core and 22 widget cases. The checking-state change in
  finding 10d remains documented as defensive coverage, not a claimed
  reproduced behavior regression.
- All **six** fresh light/dark captures pass, outside Git in
  `.flutter-previews/077-code-round-1-shots/`, named
  `configuration-{llamacpp,ollama,vllm}-{light,dark}.png`. Provider operations
  used private fixtures and injected hooks; no running provider was changed.

Logs: `/tmp/maprisma-077-independent-complete-branch-gate.log`,
`/tmp/maprisma-077-independent-python-complete.log`,
`/tmp/maprisma-077-independent-typecheck-complete.log` and
`/tmp/maprisma-077-independent-screenshots-complete.log`.

The final amendment adds only this review documentation. Executable and test
trees match the validated source. The pre-existing untracked
`docs/plan-maprisma-experience.md` is untouched and excluded from every commit.

## Code review round 2 (independent)

Antigravity's independent round 2 confirms all eleven original findings are
fixed with tests and raises four further points. Changes use private provider
fixtures; no running provider is started, stopped or reconfigured.

1. **Major — partial offload does not validate CPU-resident memory**
   (`provider_config.dart:352`). Validation now also compares full model
   weights minus GPU weights, plus full KV minus GPU KV for verified cache
   placement, against total and available RAM. Unverified CPU KV contributes
   zero, so uncertain placement cannot produce a false refusal. The GPU-side
   reserve is counted once. Capacity errors and the available-memory warning
   are deduplicated when both sides exceed their respective limits.

   Ten new core/route cases cover the 20 GiB model on an 8 GiB GPU and 16 GiB
   RAM, output-only GPU offload with huge CPU cache, unverified CPU weights,
   unknown-cache lower bounds, available/zero-available RAM, warning
   deduplication, exact RAM equality without a second reserve, sliding-window
   fixed memory, and rejection by both preview and `configAnswer`. Seven fail
   against the pre-fix source; the other three pin uncertainty and boundary
   behavior. All ten pass after the fix. Task §4 and all eight manuals explain
   the RAM constraint. Existing translated messages are reused.

2. **Minor — Strata misclassified as GPU-only**
   (`provider_config.dart:45`). This was already fixed by `ce3eaf7` before this
   round: GPU-only placement requires the utilization role, and launch advice
   selects RAM rather than GPU sizing. The quoted context-based predicate is
   absent from the current branch. Both existing Strata regressions (CPU-only
   and 512 MiB GPU) were verified again. Temporarily restoring the old
   predicate makes both fail; restoring the current predicate makes them pass.
   They exercise fit, errors, recommendation, `strata launch` from
   `models.config_check`, and empty-value AI advice. No duplicate production
   fix or redundant test was added.

3. **Nit — duplicate draft lookup** (`main.dart:1999`). `_performancePage`
   passes its existing `draft` to `_readConfiguration`, removing the second
   `_configurationDraft` call. The current lookup is idempotent, so the eight
   real-app draft/consumed-proposal checks pass both before and after this
   cleanup. There is no claimed behavioral red test for this nit; counting
   private calls or source text would only mirror the implementation.

4. **Nit — Jan's two GPU-layer chips crowd the wide-layout editor**
   (`provider_config_view.dart:671`). Rows now use the table layout only when
   its editor column has room for text, both steppers and the section's
   special-value chips; otherwise they stack. The six width cases cover 500,
   680, 700, 720, 1050 and 1400 px. Before the fix, 720 px produces a 56 px
   overflow and no editable text width; 1050 px leaves only 30.3 px for text.
   After the fix, every case has at least 64 px of actual `RenderEditable`
   width, both chips are reachable, and typing, stepping and selecting -2/-1
   work without overflow. The focused configuration/performance run passes
   32 widget cases, and the eight real-app draft cases pass.

Red/green evidence is outside Git under `/tmp/maprisma-077-r2-*`: core
regressions, Strata mutation verification and Jan layout checks. The duplicate
lookup's before/after app logs are `gui-draft-before.log` and
`gui-draft-green.log`. Ordered commit gates and final suite/review results are
recorded below after verification. The standing exception for the seven native
Python parity baseline failures still applies; they will not be called green.

### Ordered commit checks

The core commit's staged-files `tools/test-changed` is fully **green**:
**503 core tests**, **134 selected widget tests**, **14 Python checks**,
formatting and both analyzers. This gate includes the ten new RAM cases and
the six Jan width cases. No route shape changed, so no protocol commit is
needed. Jan's narrow and wide captures are outside Git in
`.flutter-previews/077-code-round-2-shots/`.

The GUI commit's plain `tools/test-changed` is fully **green**: **124 selected
widget tests**, **eight Python protocol checks**, formatting and analyzer.
Four light/dark Jan captures at 700 and 1400 px pass and use a named per-model
selection. The full branch gate and the complete suites run next.

### Split verification and follow-ups

The first full round-2 `tools/test-changed --base main` run passes **503 core
tests**, **415 Flutter tests**, **69 differential cases**, AOT transport,
formatting and analyzers. Native Python executes **1,441 tests**, reproducing
only the same seven authorized baseline methods (four failures, three errors).
Standard-shell Python is **1,441 OK (52 native checks skipped)**; typecheck is
**0 errors, 0 warnings, 0 information diagnostics**. DISPLAY is unset.

**Claude GUI: CLEAN.** Source inspection verifies the single draft lookup,
unchanged consumed-proposal handling, the column-width calculation, consistent
headers/rows, and the six real input/interaction width checks. The reviewer
agrees there is no behavioral red case for the idempotent draft cleanup. No
tests, builds, edits or live provider operations were run by the reviewer.
Output: `/tmp/maprisma-077-r2-claude-verify.md`.

Antigravity verifies the RAM formula, single reserve, unknown-cache lower
bound, warning/error deduplication, route/AI refusal and the prior Strata fix,
but finds two follow-ups. Full read-only output:
`/tmp/maprisma-077-r2-agy-verify.md`.

1. **Minor — the SWA test did not isolate fixed memory.** At an 8 GiB RAM
   limit, weights plus ordinary attention already overflowed before adding
   SWA memory. The limit is now 12 GiB: about 11.94 GiB fits without the fixed
   term, while about 12.88 GiB including it must fail. Deliberately dropping
   fixed memory from `kv()` now makes that regression fail. Production cache
   arithmetic was correct and remains unchanged.
2. **Nit — unknown RAM (`0/0`) incorrectly warns.** The availability check now
   requires a known positive `ram_total`. A new unknown-RAM case fails before
   the guard and passes after it; the existing known-total/zero-available case
   still warns. This distinguishes missing `/proc/meminfo` from actual memory
   pressure without changing any valid capacity constraint.

The follow-up focused core/route run passes **70 cases**. Mutation and
regression evidence is in `/tmp/maprisma-077-r2-swa-mutation-red.log`,
`/tmp/maprisma-077-r2-unknown-ram-red.log` and
`/tmp/maprisma-077-r2-followup-green.log`.

The follow-up core commit's staged-files `tools/test-changed` is fully
**green: 504 core tests, 134 selected widget tests and 10 Python checks**,
with clean formatting and both analyzers. GUI source is unchanged from
Claude's CLEAN round-2 review. A new full branch run verifies the added
unknown-RAM case and stronger SWA boundary before core re-review.

## Code review round 3 (independent)

The independent review confirms the earlier fixes and identifies one minor
and two nits in the partial-offload RAM work. The first two were already in
the ongoing core follow-up; the negative-context correction is included in
that same amended `core:` commit.

1. **Minor — unknown RAM emits a false availability warning**
   (`provider_config.dart:397`). The warning requires `ramTotal > 0`, so missing
   `/proc/meminfo` represented by total/available `0/0` produces neither a RAM
   error nor an availability warning. Known positive total with zero available
   memory still warns. The unknown-RAM regression failed before the guard and
   passes after it; both states are covered together.
2. **Nit — SWA fixed memory was not isolated by the test**
   (`provider_config_round2_test.dart`, sliding-window case). Total and
   available RAM are 12 GiB, between roughly 11.94 GiB without the fixed term
   and 12.88 GiB with it. A mutation which drops `fixed` makes the test fail;
   correct production arithmetic passes. No cache formula was changed for
   this test correction.
3. **Nit — CPU KV uses an unclamped context from existing configuration**
   (`provider_config.dart:384`). The CPU calculation now uses the same
   `math.max(0, configInt(...))` normalization as `_fit()`. The new case stores
   `ctx-size = -1` in existing settings and edits only threads. CPU weights
   plus fixed SWA require exactly 1 GiB; RAM is 32 KiB lower. Before the fix,
   the negative context subtracted 64 KiB, incorrectly allowing the edit.
   After the fix, both validation and `configAnswer` reject it. This is a real
   red/green regression rather than a negative input rejected by range checks.

### Scoped validation requested by Uwe

Uwe's latest instruction is **“retest only what is changed”**. It supersedes
the earlier broad rerun requirement: the older-source full branch run was
stopped, and no further full suites were started. The completed earlier
round-2 results remain historical results above, not claims for this amendment.

- **12 affected RAM/core-route cases pass** in
  `test/provider_config_round2_test.dart`.
- Formatting checks cover only the changed source and test. Direct analysis
  of those two files reports **no issues**.
- Red evidence: `/tmp/maprisma-077-r2-unknown-ram-red.log`,
  `/tmp/maprisma-077-r2-swa-mutation-red.log` and
  `/tmp/maprisma-077-r3-negative-context-red.log`.
- Final focused output: `/tmp/maprisma-077-r3-focused-green.log` and
  `/tmp/maprisma-077-r3-analyze.log`.

There are no route, UI-text or provider-operation changes. Tests use cached
facts and temporary homes. The existing untracked experience plan is untouched
and excluded from the commit.

### Final focused verification — CLEAN

**Antigravity: CLEAN for all three round-3 fixes.** The read-only review
verifies unknown versus exhausted RAM, the isolated SWA boundary, identical
CPU/GPU context normalization, and the existing-file negative-context case
including `configAnswer` rejection. No tests, builds, writes, branch switches,
credential/preset reads or provider operations were performed by the reviewer.
Full output: `/tmp/maprisma-077-r3-agy-verify.md`.

The final amendment records this verdict only. Source and test trees are
unchanged from the **12 passing affected tests** and clean changed-file
analysis. No full-suite rerun was performed after the scope restriction.
