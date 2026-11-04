# Review — Tasks 050 and 051: Calm map, Ask AI parity and prompt examples

Branch: `task/050-ask-ai-parity` (051 is a follow-up on the same branch)
Tasks: [docs/tasks/050-ask-ai-parity.md](../tasks/050-ask-ai-parity.md),
[docs/tasks/051-ask-ai-examples.md](../tasks/051-ask-ai-examples.md)
Plugin side: `maprisma/omarchy-maprisma` 0.2.0 (install panel and `install-appimage`), reviewed in the same rounds.

## Round 1 (Claude, 2026-11-04, uncommitted worktree on feacab1)

1. **High** `packages/maprisma_core/lib/src/smart_card.dart` smartMapEdit: an Ask AI provider connection never
   passed both smartMapEdit and `CoreService.preview` (model optional vs required; model checked as a map id
   vs a model name).
   > Author: fixed: the provider branch hands the route exactly kind/command/item/remove/model/use_now, the model
   > as a name (map id or label accepted), checked like the route (`modelKey`, `chatModels`).
2. **High** `install-appimage`: the app started with `&` died with the terminal (SIGHUP to the process group).
   > Author: fixed: `setsid -f … </dev/null`.
3. **High** `flutter_app/lib/map_layout.dart` mapCollaborationColor: blue themes (Tokyo Night, Catppuccin)
   gave red collaboration lines.
   > Author: fixed: the hue keeps at least 45 degrees from `colors.error`; test with five themes.
4. **Medium** `flutter_app/test/task_cards_app_test.dart`: seven tests failed on the branch (green on main).
   > Author: fixed: red status for any core `warn` again; tests follow the compact draw dialog and nested scroll.
5. **Medium** Legend and drop notes were missing from every translation.
   > Author: fixed: all new texts in 8 languages, KEYS and generated assets.
6. **Low** Map edit errors dropped the service's reason.
   > Author: fixed for rule refusals (`failureText(tr, error)`); other errors stay generic by design.

Usability points also addressed: success as a note with Undo instead of modal dialogs, reasons for refused
drops, arrows and calm finished agent links, installer lock (`flock`), progress bar, notice without a terminal
launcher, accurate README/marketplace wording ("checked", not "verified"). Kept open by decision: no
provider-to-model lines; one collaboration colour for all helper agents.

## Round 2 (Claude, 2026-11-04, uncommitted worktree)

Five Low findings (stage file after a signal in mktemp, vague missing-model note, untranslated Ask AI map-edit
errors, model-name test coverage, signal test coverage).
> Author: fixed: stage path named before it is created, "This model is no longer on this PC.", translated
> `smartMapUnavailable`/`smartMapChatModel`, more rejected names, TERM/INT/after-commit signal tests.

CLEAN

## Round 3 (Claude, 2026-11-04, uncommitted worktree)

Two minor notes: a second signal could cut the installer's clean-up short; moving a model line onto a missing
model of the same provider gave "Only a model from … can replace this one."
> Author: fixed: `cleanup()` ignores INT/HUP/TERM; the missing target is named first; tests for both.

CLEAN
