# Flutter local connection authoring — implementation response (2026-10-28)

Plan and current migration inventory: [plan-flutter-connections.md](plan-flutter-connections.md).

This slice is implemented on main in the Flutter repository. It does not complete
the full migration or replace the production application. No commit, install,
GTK/plugin sync, real server launch, AI query or publication was performed.

## Completed

1. **Current parity inventory.** The plan distinguishes implemented/tested flows,
   remaining GTK actions and desktop/packaging validation. The active Flutter
   checklist and frontend README no longer describe old loopback/PDF restrictions
   as current blockers. Dated implementation notes remain historical. Installer
   service code is recognized separately from its still-unwired Flutter UI.
2. **Custom MCP definitions.** Connections has a local authoring form for stdio,
   HTTP and SSE. Users choose registered installed agents. Stdio executable and
   arguments are separate fields, one argument per line; env/header values are
   obscured. The service validates exact fields, names, transport, recipients,
   limits and control characters, then reuses adapter-owned `mcp_ctl.plan` files.
   Existing definitions with the same name are disclosed before replacement.
   New commands/URLs are saved configuration data, never execution parameters for
   Asterism. Agents may start a configured server when reading it.
3. **Local skill-set attachment.** Users select an existing folder containing
   skill directories with SKILL.md and choose agents. Metadata discovery is
   explicit, at most one category level, 200 entries per directory and 1,000 total.
   No skill file body or credential file is read. Existing adapter logic produces
   links or settings-list changes. Native access is explained without modifying
   it. Source files remain in place and future edits remain visible to agents.
   Scripts are disclosed, not executed. Each preview supports at most 32 selected
   agents and 200 added/removed links; conflicting names are refused and identical
   links are merged.
4. **Private worker skill plans fixed.** Previously the service always queued
   connection apply, but the private wire rejected links, making ordinary skill
   connections fail for link-based agents. Wire version 2 carries bounded links;
   version 1 remains decodable. Commands, arbitrary file installation and retire
   operations remain refused. Link payloads cross the inherited private FD, never
   process arguments or public results. Workers recheck source SKILL.md metadata
   and the existing core checks destination collisions/stale configuration before
   applying. Public results retain opaque Undo handles. Existing backups/Undo
   preserve later edits.
5. **One card flow.** Both new forms use the existing connection review → worker
   progress → result/Undo path. The form and search survive cancelling a review;
   no apply happens on Cancel. Public previews include recipient names, file
   paths/change counts and explanatory notes, never raw configuration, argument,
   env/header or token-bearing URL values.
6. **Width leftover fixed.** TaskHost and completion scanning share one half/full
   decision. The application records actual map-area LayoutBuilder constraints
   instead of using window MediaQuery width. An app test constrains the map to
   880 px in a 1400 px window: the card is full and model completion causes no
   forced graph scan.
7. **Eight languages and manual.** New labels/notes are in all eight Flutter
   assets. Seven source JSON translation files were appended without changing
   existing values/order. The new local-connections manual section is translated
   and stamped in seven translations; all eight PDFs rebuilt.

## Validation

- `tools/flutter-dev check`: clean formatting/analyzer, **55 Flutter tests passed**.
- `python3 -m unittest discover -s tests -q`: **1,395 tests passed**, all modules.
- `UV_OFFLINE=1 tools/typecheck.sh`: **0 errors, 0 warnings**.
- Actual private-worker tests add/remove skill links, Undo, refuse a disappeared
  source and preserve a destination file created after preview.
- Authoring tests exercise real adapter-format planning in temporary files,
  multi-agent apply/Undo, replacement notices, bounded/invalid requests, native
  skill access and private previews. The new executable is never launched.
- Flutter form tests cover argument boundaries, explicit recipients, obscured
  header values, selected folder forwarding and review cancellation. App tests
  record the author-preview route and verify that Cancel performs no apply.
- Native Linux Devel build succeeded, not launched:
  `/mnt/Data/Projects/asterism-flutter/.flutter-previews/preview-skepcq6t/flutter_app/build/linux/x64/release/bundle/asterism`.
- Dart transport checks and `git diff --check`: passed.
- Existing translation values and order were compared with HEAD and preserved
  across all seven source files. All eight generated assets/manual PDFs verified.

## Remaining work

Online MCP/skill catalogs, skill fetching/installing, tool checks, richer server
management and remaining GTK actions are not claimed complete. Desktop/VM and
full migration/packaging review remain outstanding. Existing `about` and
`running-agents` manual fingerprint drift remains separate; only the new
`connect-local-flutter` section was stamped, without masking unrelated drift.


## Claude review / archive checkpoint — 2026-10-28

Committed on main as `69464c8` after Claude's review, with no Medium or higher
finding. Claude rechecked the bounds, private summaries, skill-source validation,
wire compatibility, actual map-area width rule and additive translations; analysis
and 55 Flutter tests passed. This plan and response are now archived.

Two low argument-form issues remain for the next related code change: empty lines
are dropped, so intentionally empty arguments cannot be represented, and pasted
CRLF can leave a trailing carriage return in an argument. This documentation
archive does not change application code. Nothing was pushed.
