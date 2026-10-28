# Idea: manage agent and provider add-ons on the map, without the Setup page (2026-10-28)

Uwe's idea, written for Codex. **Flutter only**: GTK Asterism and the Omarchy plugin are not changed for this.
Fits Uwe's goal that the map configures everything (connect, disconnect and set up by drawing or clicking on the
map, with tooltips and Undo). If it is taken up, link it from `docs/plan-flutter.md` and write a plan file first.

## Uwe's words

> Get rid of the setup page and make this agents and provider add-ons management possible in the map. To keep it
> easy to use: a normal layer like now, and the possibility to expand a group card, which then should be centred
> and alone visible, with the not installed add-ons and the action submenus like now in the setup page. Problem:
> when no category group card is existing, then we have to create a dummy one.

## Today (Flutter)

- **Map:** `agent_map.dart` shows four columns: *MCP servers and skills*, *Agents*, *Providers*, *Models*. It shows
  only what is set up.
- **Setup page:** `setup_view.dart` is the welcome page (Look at this PC / Skip, the add-ons found on this PC
  already ticked, Switch on / Later). Service methods are `setup.detect` and `setup.apply`.
- **Add-ons page:** `addons_view.dart` lists installed add-ons (on/off switch, Details with Reads/Sends) and
  available ones from the signed catalog (Get add-on). Service methods are `addons.catalog` and `addons.install`.
  Changes are blocked while agents run.
- **GTK reference for the menus:** `setup_page.py` `addon_entries()` / `addon_menu()` / `sign_in_entries()`. They
  provide *Update add-on to x.y*, *Add-on…* (what it reads, sends and may do; update or remove) and, for an online
  provider, *Sign in to <agent>…*, plus the node's own menu (update, start, details, remove…).

## Proposal

### Normal layer (unchanged)

The map looks as it does now. Each category has a **group card** at the top of its column (Agents, Local LLMs,
Online providers; MCP servers and skills later, if wanted). It shows its name, a count ("3 on · 2 more
available") and an expand button ⤢. A click on an item card works as today.

### Expanded group (focus view)

- Expanding a group card (⤢, double-click, or **Enter** on a focused card) moves it to the **centre**, and it is
  then the **only thing visible**. The other columns and the edges fade out; nothing else changes. Pan and zoom are
  kept and come back on collapse.
- Inside the expanded group:
  - **On:** add-ons that are installed and switched on, as cards with their ⋯ menu.
  - **Off:** installed but switched off, dimmed.
  - **Not installed:** add-ons from the signed catalog, with dashed outlines and **Get add-on**. The catalog is
    loaded only after an explicit **Look for add-ons online**, as today. Without it, the section says so and offers
    the button.
- The ⋯ / right-click menu of each card holds the actions from today's Setup and Add-ons pages:
  - Switch on, Switch off
  - Update add-on to x.y
  - Add-on… (details: reads, sends, may do; remove)
  - Sign in to <agent>… (online providers)
  - The node's own actions where it is on the map (start, update, details…)
- **Back / Esc / Backspace** or a click on the empty background collapses the group. Every change has a tooltip and
  Undo, as on the map today.
- Changing add-ons keeps the existing guard: while agents run, the actions are disabled with the existing
  "Finish running agents before changing add-ons." text.

### Dummy group card

When a category has nothing set up (for example, no local LLM installed), the column still shows its group card
as a **dashed placeholder**: "Local LLMs, none yet; expand to add one". Expanding it opens the same focus view with
only the "Not installed" section, so every category can always be reached from the map. A placeholder is pure UI:
it is never saved as a node, never counted, and never sent to AI help.

### What happens to the Setup page

- `setup_view.dart` and its navigation entry are removed, and the add-on lists in `addons_view.dart` move into the
  focus view. What stays of the Add-ons page (signing notice, catalog settings) moves to Settings or into the
  focus view's header.
- **First start / welcome:** the map opens with a short welcome bar (Look at this PC / Skip, as now) and then
  shows the **Agents** group expanded, with the add-ons found on this PC pre-marked and **Switch on / Later** in a
  fixed bottom row. This keeps today's E1 fix. After Switch on, the group collapses into the normal map.
- The service methods stay (`setup.detect`, `setup.apply`, `addons.catalog`, `addons.install`); only the UI
  moves.

## Rules to keep

- **Signing:** only add-ons signed by Uwe Bruckhaus are offered and loaded. New add-ons stay off until switched
  on.
- **Network:** no network access without the explicit "Look for add-ons online".
- **Languages:** 8 languages for every new text, and a manual chapter in all 8 languages with PDFs.
- **CPU:** the expand/collapse animation is short (≤250 ms) and nothing animates while idle. The AI Map must stay
  at about 1 % CPU (`tools/profile-flutter-map.py`).
- **Keyboard:** focus view reachable by keyboard; Esc and Backspace go back; never close on a bare Super press.
- **Tests:**
  - expand and collapse
  - dummy card for an empty category
  - no catalog request before consent
  - actions disabled while agents run
  - welcome flow with Switch on / Later visible at the default test size
  - widget tests run on the host, with `pumpAndSettle` settling (see S1 in `review-claude-2026-10-28-system-map.md`)

## Open questions for Uwe

1. Should **MCP servers and skills** and **Models** also get expandable group cards, or only agents and providers
   (the add-on categories)?
2. Should switching an add-on on or off act **at once, with Undo** (map style), or keep today's ticks + **Apply**?
3. Should the System Map get the same group expand later (disks, runtimes, tools)?

## Uwe's decisions (2026-10-28)

All three open questions: **yes**.
1. **All four map categories get expandable group cards:** MCP servers and skills, Agents, Providers (local LLMs
   and online providers), and Models.
2. **Switching acts at once, with Undo** (map style). There is no tick + Apply on the map. The welcome flow keeps
   one **Switch on** for the pre-marked set, which counts as one action with one Undo.
3. **The System Map gets the same group expand later** (disks, runtimes, tools), after the AI Map version works.

## How the dummy card appears (agreed 2026-10-28)

**Rule.** The map adds the dummy while drawing; the backend doesn't decide it. Every column always has exactly one
group card at its top:
- **Category has set-up nodes:** a **real** group card.
- **Category has none:** a **dummy** group card.

**When.**
- **First start:** nothing is set up, so all four columns show a dummy card. The map is never an empty screen.
- **Later:** if the last item of a category is switched off or removed, its real card turns into a dummy. When
  one is added again, the dummy turns back into a real card.

**What the dummy never is:** it is never saved, never counted in totals, never sent to AI help, never the end of an
edge, and never a drop target for connecting.

**Look:**
- dashed border, a ＋ icon and a muted colour
- tooltip "Nothing set up yet. Expand to add one"
- "Found on this PC" count: when `setup.detect` already found add-ons for this category, the card says "3 found
  on this PC · Expand" instead of "none yet"

```
 MCP servers & skills   Agents              Providers           Models
┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐ ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
╎ ＋ MCP servers     ╎ ╎ ＋ Agents        ╎ ╎ ＋ Local LLMs    ╎ ╎ ＋ Models        ╎
╎ none yet           ╎ ╎ 3 found on this  ╎ ╎ 1 found on this  ╎ ╎ none yet         ╎
╎ Expand to add one  ╎ ╎ PC · Expand      ╎ ╎ PC · Expand      ╎ ╎ Expand to add one╎
└╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
```

**Expanding.** Click, double-click or Enter expands a dummy like a real group card. Since nothing is on yet, only
the **Found on this PC** and **Not installed** sections show.

**First start.** There is no Setup page any more:
1. The map opens with the four dummy cards and a short welcome bar (Look at this PC / Skip).
2. The **Agents** dummy expands by itself, centred, with the found agents pre-marked and **Switch on / Later** in a
   fixed bottom row.
3. **Switch on:** one action with one Undo. The group collapses, and the Agents column now has a real card with
   the agents.
4. **Later:** the group collapses and the Agents dummy stays.

The other columns stay dummies until something is added there.

Plan: `docs/plan-map-addons.md`.
