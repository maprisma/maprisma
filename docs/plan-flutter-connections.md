# Plan: Flutter parity inventory and local connection authoring (2026-10-28)

Continue the full migration on `main`, under AGENTS.md and plan-flutter.md. This
slice completes local custom MCP authoring and attaching an existing skill set.
It does not replace the production entrypoint, change the GTK checkout/plugin,
execute new MCP commands, fetch online catalogs or publish anything.

## Current parity inventory

| User flow | Flutter source / state | Remaining GTK actions / validation |
|---|---|---|
| Agents, projects, embedded/external terminals | agent_* views, project_start_menu.dart, terminal_sessions.py; implemented/tested | Desktop keyboard/paste/selection, supervision, singleton and clean-VM checks |
| AI/System Map, groups, task cards | agent_map.dart, map_addons_focus.dart, system_map_view.dart, task_card.dart; implemented/tested | Map editing/layout parity, accessibility, desktop appearance/performance |
| Setup and signed service add-ons | map welcome/focus + flutter_addon_*.py; implemented/tested | File import and Flutter feature/extension UI contract (addons_page.py) |
| Providers and models | providers_view.dart, provider_connections.dart; implemented/tested | Tuning/full model details, starter-model guidance (models_page.py, first_agent_page.py) |
| Existing MCP/skill connections | connections_view.dart, flutter_connections.py; implemented, skill-link worker transport gap found | This slice: custom MCP definitions and local folder attachment. Later: catalogs, tools/checks, richer details, update/remove management (mcp_pages.py, connect_page.py, skills_page.py) |
| First-agent/installation | first_agent_view.dart; initial checklist and agent actions. flutter_installers.py service exists | Wire prerequisite/runtime installer UI, API-key entry and return-to-guide flow (install_dialog.py, configure_menu.py, first_agent_page.py) |
| Usage, health, security, subagents | usage + System Map health + five reader formats; implemented/tested | Broader security controls, remaining readers and collaboration views (details_pages.py, subagents_page.py) |
| Jobs and helper | flutter_tasks.py workers and guarded help; implemented/tested | Durable retry/resume/history and full helper flows (jobs.py, ai_helper.py) |
| Settings/help/notifications | settings_view.dart and existing map/help surfaces; partial | Full settings action inventory, Help/notifications/manual opening integration (settings_pages.py, info_page.py) |
| Identity/migration/delivery | identity.py, config_migration.py, native Devel builds; implemented/tested | Bundle Python/dependencies, Linux/AUR/AppImage clean installs, final desktop/Claude review |

“Implemented/tested” means source and automated tests, not desktop/VM sign-off.
Existing validation at the start: 50 Flutter tests, 1,381 Python tests, clean
analysis/typechecking, all eight PDFs rebuilt. Earlier sandbox-only blockers and
counts in plan-flutter.md are historical, not current requirements to rerun on a
separate terminal.

## Implementation

1. Add bounded custom-MCP and selected-local-skill-folder preview routes. Reuse
   adapter-owned configuration plans, structured summaries, opaque expiring
   handles, private worker handoff, backup and Undo. No command execution from
   new definition fields and no credential-file reads.
2. Fix the private connection wire to carry trusted, bounded skill link plans;
   continue rejecting commands, copied files and retire operations.
3. Add inline authoring in the existing Connections card. Pick registered agents,
   edit a stdio/HTTP/SSE definition or select an existing skill-set folder, then
   use the existing preview → apply → result/Undo flow. Preserve form/search state.
4. Use the actual map-area constraints for task-map visibility and completion
   scans while this code is being touched, resolving Claude's low-width leftover.
5. Regression-test actual worker skill links/Undo, stale collisions, strict input
   bounds and private summaries, plus form wiring and authoring cancellation.
6. Update eight languages/manuals, reconcile the active checklist, run full
   Flutter/Python checks and build the isolated Devel preview. Record results in
   plan-flutter-connections-responses.md.

Online MCP/skill catalog search/download/installation, tool probing and direct
API-key entry remain explicit next slices; they must not be marked complete by
adding the local forms.
