# Plan: group cards, dummy cards and add-on management on the map (Flutter), 2026-10-28

For Codex. Source of the decisions: `docs/idea-map-addons.md` (Uwe, 2026-10-28, including "How the dummy card
appears"). **Flutter only**: GTK Asterism and the Omarchy plugin are not changed. Link this plan from
`docs/plan-flutter.md`. Work in this tree only, with no commit, push, release or live-plugin sync unless Uwe says
so. AGENTS.md rules apply: 8 languages, manual, no credential files, tests and typecheck before handing back.

## Before starting

Answer `docs/review-claude-2026-10-28-system-map.md` (S1–S6) first. S1 matters here: the focus view and welcome
use dialogs and progress bars, so no indeterminate progress bar may run while the UI waits for the user. Otherwise
the widget tests can't settle.

## Decisions (fixed)

1. **Group cards:** all four AI Map categories get an expandable group card: MCP servers and skills, Agents,
   Providers (local LLMs and online providers) and Models.
2. **Dummy card:** a category with nothing set up shows a dummy group card. It is added by the map UI, is never
   saved or counted, never sent to AI help, and never an edge end or drop target.
3. **Switching:** add-on changes act at once, with Undo. There is no tick + Apply on the map. Welcome's
   **Switch on** for the pre-marked set is one action with one Undo.
4. **Setup and Add-ons pages are removed** from the Flutter UI. The service methods stay.
5. **System Map:** gets the same group expand later (step 7), after the AI Map version works.
6. **Scope:** Flutter only.

## Today (facts)

- **Map:** `agent_map.dart` columns: `MCP servers and skills`, `Agents`, `Providers`, `Models` (default
  `columns`). Fed by `map.snapshot` (persistent scanner, ~1.3 % CPU, `tools/profile-flutter-map.py`).
- **Welcome:** `setup_view.dart` (Look at this PC / Skip, detected add-ons pre-ticked, fixed Switch on / Later
  row). Service methods `setup.detect`, `setup.apply`, `setup.later` (`flutter_backend.py:403-418`) and
  `setup_needed` / `setup_done`.
- **Add-ons:** `addons_view.dart` (installed with switch and Details: Reads/Sends; available from the signed
  catalog). Service methods `addons.list`, `addons.set_enabled`, `addons.catalog`, `addons.install`
  (`flutter_backend.py:387-425`).
- **Navigation:** `_showSetup` / `_showAddons` booleans in `main.dart` (opened at `:1040`, `:1176`).
- **GTK menu reference:** `setup_page.py` `addon_entries()`, `addon_menu()`, `sign_in_entries()`. They provide
  Update add-on to x.y, Add-on… (reads, sends, may do; remove), and Sign in to <agent>… for online providers.
- **Existing add flows** in Flutter: model download (`providers_view.dart`), connections (`connections_view.dart`),
  existing installs and model folders (System Map).

## Steps

Each step ends with:
- Python tests green and typecheck 0
- `flutter analyze` clean
- `flutter test --timeout 60s` green **on the host**
- a short note in `plan-flutter.md`

### 1. Inventory (no code)

List every action of `setup_view.dart`, `addons_view.dart` and the GTK menus above, with the place where each will
live on the map: group card, card ⋯ menu, focus-view header, Settings, or welcome bar. For MCP servers, skills
and models, list which add flows already exist in Flutter. A missing flow (for example adding an MCP server or a
skill folder) goes in the responses file as a gap; don't invent one in this plan. Put the table at the top of
the responses file. **Nothing may be lost.**

### 2. Group cards and dummy cards (UI only)

- **Group card model:** add `MapGroup {category, real|dummy, count, found}` built in Dart from the graph and the
  existing `setup.detect` result. The backend graph is unchanged.
- **Real group card:** at the top of each column, showing name, count ("3 on · 2 more available") and an expand
  button ⤢.
- **Dummy group card:** dashed border, ＋ icon, muted colour.
  - Text: "none yet · Expand to add one", or "N found on this PC · Expand" when `setup.detect` found add-ons for
    that category.
  - Tooltip: "Nothing set up yet. Expand to add one".
- **Switching between them:** a dummy turns into a real card as soon as the category has a node, and back when the
  last one goes. The switch happens without a scan of its own; it uses the next `map.snapshot`.
- **Exclusions:** dummies never enter `_graph`, the cache, AI help prompts, counts, edges or drag targets.
- **Tests:**
  - empty graph → 4 dummies
  - one agent → Agents real, the other three dummies
  - removing the last item → dummy again
  - a dummy is not a drop target
  - a dummy is not in the AI-help facts

### 3. Focus view (expand / collapse)

- **Expanding:** ⤢, double-click or Enter on a group card moves it to the centre, and it is the only thing visible.
  Other columns and edges fade out in ≤250 ms. Nothing animates afterwards.
- **Collapsing:** Back, Esc, Backspace or a click on the empty background. Pan, zoom and selection are restored.
  Never close on a bare Super press.
- **Sections:**
  - **On:** set up, with each card's normal map menu
  - **Off:** installed, switched off, dimmed
  - **Found on this PC:** detected by `setup.detect`, not on
  - **Not installed:** signed catalog entries, dashed, with **Get add-on**
- **Online catalog:** loaded only after **Look for add-ons online**. Without it, the section explains this and shows
  the button. No network before that.
- **MCP servers and skills / Models:** the same view. Its "Not installed" section offers the existing add flows from
  step 1, for example **Download model** or **Use model folder**.
- **Tests:**
  - expand and collapse restore the view
  - Esc and Backspace collapse
  - no `addons.catalog` call before consent
  - an expanded dummy shows only the Found and Not installed sections

### 4. Actions at once, with Undo

- **Card ⋯ / right-click menu:**
  - Switch on, Switch off (`addons.set_enabled`)
  - Update add-on to x.y (signed catalog)
  - Add-on… (details dialog: reads, sends, may do; remove)
  - Sign in to <agent>… (online providers with installed agents)
  - the node's existing map actions
- **Undo:** each switch is one action with an Undo snackbar. Undo calls `addons.set_enabled` with the previous
  state. Install and remove keep their existing confirmation and backup/Undo rules.
- **Guard:** keep it. While agents run, add-on actions are disabled with "Finish running agents before changing
  add-ons."
- **Tests:**
  - switch on, then Undo restores it
  - disabled while an agent runs
  - Update only appears when the signed catalog has a newer version
  - Sign in appears only for online providers with an installed agent

### 5. First start without the Setup page

1. When `setup_needed` is set, the map opens with the four dummy cards and a short welcome bar: Look at this PC /
   Skip, the existing text and the System Map entry.
2. The **Agents** group expands by itself, with the detected agents pre-marked and **Switch on / Later** in a fixed
   bottom row (keep the E1 layout).
   - **Switch on** calls `setup.apply` with the marked set: one action, one Undo. The group collapses and the
     column shows its real card.
   - **Later** calls `setup.later`. The group collapses and the dummy stays.
3. Detection still pending: Switch on stays disabled, as today.
4. **Tests:**
   - first start shows 4 dummies and the expanded Agents group
   - Switch on and Later are hit-testable at the default test size
   - Switch on → real card
   - Later → dummy
   - a second start does not auto-expand

### 6. Remove the pages

- **Remove:** `setup_view.dart`, the add-on lists of `addons_view.dart`, `_showSetup` and `_showAddons` (and their
  menu entries). The signing notice and the catalog switch move to the focus-view header (and Settings if they are
  settings).
- **Inventory check:** every row of step 1 is now reachable on the map.
- **Tests:** update the widget tests that opened those pages so they use the map.
- **Service methods:** none are removed.

### 7. System Map groups (later decision 5)

Same group card, dummy and focus view for the System Map's columns: hardware, disks, runtimes and agents, tools,
folders. It reuses the Dart widgets from steps 2–3. The actions are the existing System Map node actions; nothing
new.

### 8. Manual, cleanup, review

- **Manual:** chapter "Group cards and add-ons on the map" in all 8 languages. Cover dummy cards, expanding, the
  online catalog consent, Undo and first start, and remove the Setup page sections. Rebuild the PDFs on the host.
- **Hand back with:**
  - Python suite, typecheck, `flutter analyze`
  - `flutter test --timeout 60s` **run on the host**
  - the map profile (AI Map ≈1 %, idle with a group expanded ≈1 %)
  - the step 1 inventory
  - a responses file

Claude reviews next.

## Not in this plan

- GTK or Omarchy plugin changes
- new add-on kinds or new add flows that don't exist yet (they are listed as gaps)
- unsigned add-ons
- network access without consent
- any publication
