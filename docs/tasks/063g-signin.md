# 063g Sign-in, native limits and billing evidence

Author: Claude · Reviewer: Antigravity · Branch: task/063g-signin

## Goal
The sign-in and battery findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 2:
#2, #10, #12, #13, #14, #15, #16, #17). Without a collector, Codex's limits were asked of the first `codex` on PATH
(which can be Omarchy's lazy launcher or a mise shim), only with `~/.codex/auth.json`, and stayed shown after a
sign-out and were renewed only when its details opened; limits whose record names no time never grew old; an
estimated Hermes cost counted as a bill; an unset key still counted as a sign-in; the map accepted a drop onto an
agent's own provider that the app could not sign it in to; and `$HOME/…` wrappers were not recognised.

## Routes
`map.snapshot`: agent nodes carry `own_login` next to `own_provider` (note in `routes.json`, `source: manual`). No
params changed. The worker operation `agents.usage_refresh` now carries `program` with `rpc` and `argv`.

- **#2** `AgentCatalog.realProgram` (Python `agents.real_program`), as `omarchy-agent-usage-codex`'s
  `find_codex_binary` but without running anything: the first executable on PATH, then `~/.local/bin` and
  `~/.npm-global/bin`, then the version mise installed of one of the agent's specs (`miseSpecs`: its wrapper's,
  `spec`, its `[[install]]` mise ways; `<folder>/<version>/bin/<command>` or `<folder>/<version>/<command>`). Never
  a `lazyLauncher`: mise's shims and command wrappers, a link to mise, a script whose first 4 KiB run mise (Omarchy's
  `mise use -g …`/`exec mise x …`), or one whose head cannot be read. `planLimitsRpc` returns `(rpc, argv, program)`
  and is null without one: then nothing is asked. The worker checks the program again (absolute, named as the
  command, no lazy launcher); `askPlanLimits` never looks on PATH.
- **#13** `[plan_limits]` gains `home_env` and `store` (`docs/adapter-format.md`, `adapter_data.PLAN_LIMITS`,
  `STORE`). Codex: `home_env = "CODEX_HOME"`, `store = {file = "~/.codex/config.toml", format = "toml", key =
  "cli_auth_credentials_store", files = "file"}`. Signed in (`limitsSignedIn`, `plan_limits_signed_in`): one of the
  access files is there (a stat; in `$CODEX_HOME` by name when set, `accessPaths`), or the store setting names
  anything but `file` (keyring, auto), where only Codex can tell, so it is asked. Only plain configuration is read.
  The staleness check after a new sign-in looks at the moved files too. As a part of `plan_limits` it reaches older
  signed add-ons with that table.
- **#14** Maprisma's own usage record counts only while `limitsSignedIn`: after a sign-out `usageRecord` (with the
  adapter) and the details give no plan or limits; signed in again, they are back.
- **#15** `UsageSweep` (`flutter_app/lib/usage_sweep.dart`): the minute timer also renews the records that are due,
  each agent at most every ten minutes (`USAGE_MAX_AGE`; the core skips a fresh record), one after the other, one
  sweep at a time, in the background; the badges reload when one was renewed. Details asking on their own count.
- **#16** `MapGraph.signedIn` (`graph.signed_in`) counts named keys: Grok without `XAI_API_KEY` gets an `available`
  line. An adapter naming neither sign-in files nor keys is still unknown and so signed in, as before. `own_login`
  (`access.logins`, as Ask AI's `own_clouds`) gates `MapLayout.targetOk`, `_whyNot` and `_mapEdit`: "This agent has
  no sign-in that the app can start."
- **#17** Limits of a record that names no `limitsFetchedAt`/`updatedAt` are measured when the record file was
  written (its mtime, whole seconds: `recordWritten`, `record_written`), so they grow old like dated ones.
- **#12** `NumericSession.estimated` (`claude_sessions.Session.estimated`): a Hermes session with only
  `estimated_cost_usd` keeps that as its API value but is left out of `billed`. OpenCode's and Crush's stores keep
  one cost column, the agent's own reckoning (zero under a plan): unchanged.
- **#10** `proven` also finds a `~/` mark spelled `$HOME/`, `${HOME}/` or `~/` in a wrapper's text.

## UI
- An agent dropped onto its own provider without a sign-in the app can start is refused with "This agent has no
  sign-in that the app can start." (already translated for Ask AI; now in the GUI's keys).

## Acceptance
- `usage_refresh_test.dart`: lazy launcher, shim and link to mise never chosen, mise's installed version or an own
  install is, nothing started; keyring/auto store and a moved `CODEX_HOME` are signed in, `~/.codex` is not then;
  a new sign-in there makes the record stale; after a sign-out no plan or limits; a record without times ages by its
  mtime; `askPlanLimits` without a program asks nobody.
- `agent_detect_test.dart`: `$HOME`, `${HOME}`, `~` wrappers proven, `$HOMEX` not.
- `agent_badges_test.dart`: Hermes' estimate is no bill, its actual cost is.
- `map_chain_test.dart`: Grok `available` without its key, `uses` with it; `own_login` false for Grok, true for Codex.
- `map_layout_test.dart`, `map_editor_test.dart`: the drop refused and the reason; `usage_sweep_test.dart`.
- Python: `test_agent_details` (launchers, keyring/`CODEX_HOME`, sign-out, mtime), `test_agents`,
  `test_harnesses` (Hermes estimate), `test_inventory_graph` (Grok), `test_adapter_data` (snapshot).
