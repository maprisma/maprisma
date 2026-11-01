# 019 Rules for what may be done

Author: Claude · Reviewer: Antigravity · Branch: task/019-action-rules, on task/018-known-servers

Uwe, 2026-11-01: rules in Settings that say what Ask AI may do. Actions such as install, remove, update, connect, reconnect, for one or all categories. Default: allow all, written out as explicit rules. A scope picker: all, a category, an instance. The same for deny rules. The user manages both with a + symbol. An allow overrides a deny: all disconnects of skills denied, but disconnecting skills for Pi allowed, then the allow wins. The rules can be shown when an Ask AI action or a drawn action is refused, if a setting allows that hint (off: protects the setup from other users or children). Defined in their own popup, opened from Settings.

## The trap
"Allow all" written out as default rules, plus "allow beats deny", means no deny can ever work: every deny is beaten by a default allow. Plain allow-overrides fails Uwe's own example, because the default "allow disconnect, all" beats "deny disconnect, skills".

Other systems go the other way: Cedar and Claude Code let a deny beat any allow, and a narrow allow cannot carve out an exception, which is the opposite of what Uwe wants. Firewalls use order (first match), which users find hard to read; conflicting rules are a known complaint.

## Logic: the most specific rule wins, on a tie allow wins
Antigravity's discussion is in `docs/reviews/019-design.md`. It showed that counting fields fails: `deny *, skills` ties with a default `allow disconnect, *` and is dead, and a rule naming one folder ties with a rule naming an agent.

A rule has an effect and four fields, each `*` or a value:

- effect: allow, deny
- action: install, update, remove, connect (also reconnect and repair), disconnect, move (model folders only), start, stop
- category: mcp, skills, agents, providers, models. An item needs a category. Settings is no category, so the rules can never lock their own editor.
- item: one server, skill folder, agent, provider or model, in a normal form (`~/...`)
- agent: the agent concerned, for connect and disconnect only

Specificity: item 8, agent 4, category 2, action 1, added up. The highest decides; only rules with the same fields can tie, and then allow wins. No rule order. No match is deny: the defaults are written out, so deleting one means what it says. Restore defaults resets both lists, with Undo.

| Rule | Score | |
|---|---|---|
| allow disconnect, all | 1 | default |
| deny disconnect, skills | 3 | beats the default |
| allow disconnect, skills, agent Pi | 7 | beats the deny |
| deny disconnect, skills, one folder | 11 | beats Pi's exception |

## Enforcement in the core
One entry, `requiredChecks(method, params)`, gives every (action, category, item, agent) a request touches, and all must pass. A test fails for a route of kind change or handle without an entry.

- Also the routes with no preview: `providers.run`, `jobs.continue`, `updates.run`, `sessions.start`, `addons.set_enabled`, `setup.apply`, `found.unpack`, `system.help_apply`.
- Lists are checked item by item: `_disconnectAll`, `author_preview`, `option_preview`, `attach_preview`, `found.update_preview`.
- A line moved on the map is disconnect on the old end and connect on the new one, never `move`; moved to empty space it is disconnect.
- Checked at preview. Not again at apply: a review is modal, and the rules button in Ask AI waits while one is open.
- In `map.smart_ask` right after the helper's first answer, before a search or a second paid call.

The helper gets the rules as facts and its fixed action list stays; its answer is not trusted.

## Refused
A new error `action_refused` with a message from the core's own rule text; today the wire strips every message, so the GUI would only say "could not be completed". `action_rule_hints` on: the deciding rule in words. Off: "This is not allowed here.", and the helper names no rule and does not fall back to a web lookup. Its switch lives in the popup.

## Popup
A button in Settings opens `OverlayWindow`: an Allow list and a Deny list, a + per list, a delete symbol per row, pickers that show only what fits (no agent for install, an item only with a category). A rule for something uninstalled stays visible. A line under a row says when it can never decide. A bar at the bottom tests a request and shows the deciding rule.

## Storage
`action_rules` (at most 200) and `action_rule_hints` in `settings_schema.py`, `settings.dart`, `core_assets.g.dart`, `UI_SETTINGS`, and `routes.json`. New texts and the manual in 8 languages.

## What it is not
Not a lock. Anyone who can open Settings can change the rules, and the file is plain. Every terminal in the app, an agent started on the map too, runs under the user's account and can change anything. Recent changes can put old states back, and the background start and stop of local LLMs is not covered. For children this needs at least a PIN on the popup; that is a separate decision.

## Decided (Uwe, 2026-11-01)
The rules bind what is drawn by hand too. The helper gets them as facts, its fixed action list stays. No PIN. No `ask` action: a prompt is not checked, what it would do is.

## Not in the Python reference
Enforcement, `rules.test` and `smartRefused` are in the Dart core, which the app runs; like the smart cards they have no Python twin. `settings_schema.py` knows both settings.

## How it is built
`action_rules.dart`: the rules and `actionChecks(method, params)`. `_dispatch` in `core.dart` checks every request; a few handlers check what only they know. `action_rules_test` fails for a route of kind preview, change or handle with neither checks nor a place in `rulesExempt`. The GUI's `failureText` shows a refusal wherever a failure is shown today.
