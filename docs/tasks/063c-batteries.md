# 063c Batteries, costs and the legend

Author: Claude · Reviewer: Antigravity · Branch: task/063c-batteries

## Goal
The battery findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 1: F18, F19, F20,
F22, F23). Off Omarchy, Codex had no battery although its own app-server tells its plan limits; old limits looked
current; Hermes and OpenCode, whose sessions say what they cost, never got a cost badge; a cost per token never had
a battery; and the legend named fixed levels while the cards use Settings › Costs.

## Routes
`map.badges` gets its shape in a note (`source: manual`): a badge may now carry `stale` (a battery) and `left` (a
cost: what is left of the day's limit). No params changed. The worker operation `agents.usage_refresh` may carry
`rpc` and `argv` (checked: a protocol the app has, plain words starting with the agent's command).

- **F18** A new adapter fact `[plan_limits] rpc, argv` (`docs/adapter-format.md`; `adapter_data.PLAN_LIMITS`,
  `LIMIT_RPCS`; a newer fact, so an older signed agent-codex add-on takes it from the app's adapter). Codex:
  `rpc = "codex-app-server"`, `argv = ["codex", "-s", "read-only", "-a", "on-request", "app-server"]`. Only when
  no `omarchy-agent-usage-<agent>` collector is found and one of its `access.files` exists (a stat, never a read),
  `agents.usage_refresh` asks the program itself (`usage_rpc.dart`, as `omarchy-agent-usage-codex`'s
  `fetch_codex_rpc`: initialize, initialized, `account/rateLimits/read`, `account/read` only for a missing plan).
  8 s per answer, 20 s in all, at most 1 MiB read, then its session is killed. The record has the collector's
  shape (limits with label/percent/resetsAt, tierLabel, updatedAt, limitsFetchedAt) and is kept as
  `~/.local/state/maprisma/usage/<agent>.json`. It runs when collectors are refreshed today: once at the start and
  when an agent's details show, at most every ten minutes. Python reference: `agent_details.plan_limits_rpc`,
  `native_usage`, `ask_plan_limits`; the snapshot `tests/adapter_snapshots/codex.json` has `plan_limits`.
- **F20** Each limit keeps when it was measured (`limitsFetchedAt`, else `updatedAt`; ISO, seconds or
  milliseconds) and the collector's `limitsStale`. `LIMITS_MAX_AGE` is 30 minutes: three times `USAGE_MAX_AGE`
  (ten minutes, after which details ask for fresh usage), so two refreshes may fail or be skipped first. A limit
  without a valid reset is left out once older than that; one still to reset stays but is stale. A stale battery
  is faded on the map, and its tooltip ends with "Measured Thu 09:00: these numbers may be out of date."
- **F19** `UsageReaders.costs` adds `billed`: what the agent's own store says its sessions of the last 30 days
  cost (`NumericSession.cost`: Hermes' actual or estimated cost, OpenCode's `cost`, Crush's). `paysPerToken`
  takes it: money in its own sessions and no plan, no limits and no expired sign-in means paid per token. A plan
  or a local LLM leaves that cost 0 there, so no badge for them. The badge loop reads sessions for this only for
  readers that keep money (`SessionReaders.costReaders`). Oh My Pi and OpenClaw keep tokens only: not changed.
- **F22** `costBadge` adds `left` (what is left of the day's limit, by `charge`; only with a limit); the colour is
  still `costColour` (the same levels).

## UI
- `AgentBadge`: a cost with `left` shows the battery beside the money; a `stale` battery is faded.
- The legend takes the levels of Settings › Costs (`warnPercents`): "Yellow: {0} % or less is left.", "Red: {0} %
  or less is left." (exactly a tenth left is red, as `charge` decides with `<=`), a faded battery, and the green
  line names the day's limit. New texts in all eight languages; the manual's "Costs in the Flutter preview".

## Acceptance
- `usage_refresh_test.dart`: with no collector and a signed-in Codex, a fake `codex app-server` answers; the record
  has its plan and two windows, the details show them, the program is gone afterwards; not signed in or with a
  collector on PATH it is never asked; a silent one is killed after its time.
- `agent_badges_test.dart`: old limits without a reset expire, old or kept ones are stale with the tooltip line;
  record times in three forms; a cost's `left` (a tenth left is red); `billed` from an OpenCode database makes it
  paid per token, a plan does not.
- `agent_map_test.dart`, `map_editor_test.dart`: the cost's battery and the faded one; the legend's percentages
  at the defaults and at 60/95.
- Python: `test_agent_details` (the app-server fallback, measured/stale), `test_battery`, `test_agent_status`
  (`billed`), and the parity tests `test_dart_badges_parity`, `test_dart_costs_parity` with the new cases.
