# 056 Add cards for MCP servers, skills and models

Author: Claude · Reviewer: Antigravity · Branch: task/056-add-cards (on top of task/055-enable-found)

## Goal
From Uwe's screenshot note of 2026-11-05 (`maprisma-2026-11-05-08-56-21`): there are no add-ons for MCP
servers, skills and models, yet their expanded columns showed only the add-on section. The search and
download pages (MCP catalog, skills on the web, model download) were reachable only through Connections
or Providers and models. The GTK app ended each such section with a dashed add card.

## Routes
None.

## UI
- Map: an MCP servers card, a skills card and a model folder card served by a local LLM end with a dashed
  **+** card (`MapAddCard`, `MapCardLayout.add`): **Add MCP server** opens Connections with the MCP
  catalog, **Add skills** with the skills web search, **Add model** the model download (`ModelBrowser`) of
  the local LLM that serves the folder. An online provider's models get none, and neither does a folded card.
- Expanded MCP servers and skills or Models column: the same actions as add cards (Models: one per local
  LLM on the map, else one for the first installed). The add-on texts, switches and catalog only show for
  Agents and Providers.
- `ConnectionsView.open` ('mcp', 'skills') opens the catalog or the skills search at once.
- Texts: all came from the GTK app, already in 8 languages; four added to `tools/flutter-assets.py`.
- Manual, Expand a category: one paragraph (8 languages).

## Acceptance
- `map_layout_test.dart`: which cards get an add card and for which local LLM; its place under the last box;
  folded cards have none.
- `map_editor_test.dart`: the add cards show and report what to add; none without a handler.
- `task_cards_app_test.dart`: the MCP page shows add cards and no add-on section; the map's MCP add card
  opens the MCP catalog; the model folder's opens the download for its local LLM.
