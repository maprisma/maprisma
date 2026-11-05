# 063j Whose sign-in, which home, which record

Author: Claude · Reviewer: Antigravity · Branch: task/063j-signin

## Goal
The sign-in and battery findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 3:
#10, #11, #12, #13, #14). A keyring or auto store counted as a confirmed sign-in, so a Codex signed out of its
keyring kept an OpenAI `uses` line and its limits; the map's line looked at `~/.codex/auth.json` even with
`CODEX_HOME` set, while the battery looked in the moved home; Maprisma's own usage record was one per command, so
another `CODEX_HOME` showed the first home's limits; a signed add-on with the earlier `{rpc, argv}` table got no
`home_env` or `store`; and on Omarchy without the collector the old Omarchy record stayed the one shown although
the native refresh wrote Maprisma's own.

## Routes
None changed (`routes.json` untouched). The worker operation `agents.usage_refresh` with `program` now also carries
`home` (16 hex digits, checked).

- **#10** Probe eligibility and sign-in are two things now. `limitsProbeable` (`plan_limits_probe`): an access file
  is there or the store names a non-file place; `planLimitsRpc` asks only then, also after "signed out", so a new
  keyring sign-in is found. `askPlanLimits` marks its record `signedIn`: true when the limits came, false on an auth
  error (as `omarchy-agent-usage-codex`: "Waiting for auth"). No answer (timeout, another error) is unknown: the
  record stays, an earlier `signedIn: false` of this home is dropped. `limitsSignedIn` (`plan_limits_signed_in`): an
  access file, or the store elsewhere and `programAnswer` (`program_answer`, Maprisma's own record of this home; null
  where Omarchy's collector asks) is not false. Unknown keeps the old rule (signed in). The map's line
  (`programSignIn`) and the record's validity go by it.
- **#11** `MapGraph.signedIn` (`graph.signed_in`): a named key, else `programSignIn` (`limitsSignedIn`: the access
  files by `accessPaths`, honouring `home_env`, and the store). `~/.codex/auth.json` no longer counts with
  `CODEX_HOME` set; line and battery share one rule. Without `programSignIn` the home folder's files, as before.
- **#12** `usageHome(adapter)` (`usage_home`): sha256 of the home folder and the moved home, 16 hex digits. The core
  hands it to the worker, the record keeps it as `home`. `usageRecord`, `usagePath`, `programAnswer` and
  `usageIsStale` (now with `adapter`) treat a record of another home, or one without `home` (written before), as
  missing: no limits, and due at once.
- **#13** `withNewerFacts` merges `plan_limits.home_env` and `.store` from the app's own adapter where the add-on's
  table lacks them, like `security.sandbox` and `access.logout`; `harnesses._with_newer_facts` does the same on the
  tuple. What the add-on names stays.
- **#14** `usagePath(command, adapter)`: with the collector Omarchy's record, unchanged. On Omarchy without it, the
  newer of Omarchy's and Maprisma's own (by `limitsFetchedAt`, `updatedAt`, else the file's mtime; Maprisma's of
  another home does not count), so once the program was asked its answer is shown. `usageIsStale(native: true)`
  looks at Maprisma's own record, the one the refresh writes. Python has no Omarchy fallback to keep in step.

## UI
None. The manual's sentence ("after a sign-out they are no longer shown") now holds for a keyring too.

## Acceptance
- `usage_refresh_test.dart` (group "round 3"): a keyring store probed, an auth error makes it signed out but still
  asked, no answer makes it unknown, limits make it signed in, an auth error hides the limits; another
  `CODEX_HOME` sees no limits and is due though its sign-in is older; a record without a home counts for none; on
  Omarchy without the collector the newer record is read, with it Omarchy's.
- `map_chain_test.dart`: with `CODEX_HOME` set `~/.codex/auth.json` gives `available`, the moved one `uses`, and
  `limitsSignedIn` agrees; a keyring Codex that said "signed out" has `available`, "signed in" `uses`.
- `agent_detect_test.dart`: an add-on with only `rpc`/`argv` gets `home_env` and `store`; its own `home_env` stays.
- Python: `test_agent_details` (keyring answer, other home), `test_inventory_graph` (moved home line),
  `test_agent_facts` (earlier `plan_limits` table).
