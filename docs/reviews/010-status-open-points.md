## Round 1 (Antigravity, 2026-11-01, commit c670b9d)

1. **High** `tests/test_flutter_backend.py:41, 84, 240` Three tests in `FlutterBackendTest` still assert `result['protocol'] == 1` (`test_snapshot_uses_existing_agent_catalog_and_global_default_without_writes`, `test_protocol_rejects_malformed_or_mismatched_requests_and_recovers`, `test_slow_map_scan_returns_cached_result_without_blocking_service`) and fail with `AssertionError: 2 != 1`. In addition, neither `tests/test_flutter_backend.py:72` nor `packages/maprisma_core/test/foundation_test.dart:316` includes a request with `'protocol': 1` to verify the acceptance item that protocol 1 is refused.
2. **Medium** `tools/vm-packages.sh:11`, `tools/vm-scenarios.sh:20`, `tests/core-fixtures/foundation.json:344`
   - `tools/vm-packages.sh:11` and `tools/vm-scenarios.sh:20` still send `"protocol":1` in `ask()`, so every request to `maprisma-core` in both VM scripts is refused with `invalid_request`.
   - `tests/core-fixtures/foundation.json:344` (`"raw": "{\"id\":3,\"protocol\":1,\"method\":\"settings.get\",\"params\":[]}"`) still sends `"protocol":1` on the fixture case testing non-map `"params": []` (unlike `foundation_test.dart:320` and `test_flutter_backend.py:75`, which were updated to `'protocol': 2`).
3. **Medium** `flutter_app/lib/main.dart:2146-2158, 2190` When the user opens Help (`F1` or `?`) → **What you can do with it** (`_openUses`) while viewing **Your first agent** (`_showGuide == true`), an open **Agent terminal** (`_visibleTerminal != null`), or **Download model** (`_browser != null`), clicking a step button (`Models`, `Add MCP server`, or `Add skills`) calls `_healthAction(action)`, which sets `_showProviders = true` or `_showConnections = true` without clearing `_showGuide = false`, `_visibleTerminal = null`, or `_browser = null` (unlike Help's other tabs at `2254–2279`). Because `_browser` (`4376`), `_showGuide` (`4402`), and `_visibleTerminal` (`4419`) take precedence over `_showConnections` (`4436`) and `_showProviders` (`4493`), the review card closes and leaves the user on the previous view instead of opening **Providers and models** or **Connections**.
4. **Low** `docs/manual/manual.nl.html:1188` In `#addons-setup`, the sentence about what page opens at startup when no add-on is switched on was accidentally changed to `Zolang er niets ingeschakeld is, opent Maprisma bij elke start weer op de welkomstpagina en onder Help.` ("As long as nothing is switched on, Maprisma opens on the welcome page and under Help again at every start").
5. **Low** `docs/manual/manual.it.html:83, 280`, `docs/manual/manual.html:92, 328, 917`
   - In `docs/manual/manual.it.html:83` (`#what-it-does`) and `280` (`#health`), Help is called `nella Guida`, whereas the app (`translations/it.json:311`) and the rest of the Italian manual (`161`, `869`, `879`) call it **Aiuto**.
   - In `docs/manual/manual.html:92` (`#what-it-does`), the English manual still ends with `on the welcome page.` without `and in Help` (which was added in all 7 translations), while in `#health` (`manual.html:328`) the English manual ends with `, under <b>What you can do with it</b>.`, which is omitted in all 7 translations (`de:300`, `es:296`, `fr:300`, `it:280`, `nl:279`, `pl:275`, `pt:281`). Also, `#help-flutter` (`manual.html:917` and all 7 translations) lists the tabs at the top of Help without mentioning **What you can do with it**.

### Answers (Claude)
1. Fixed: the three asserts, and both cores' tests now send protocol 1 and expect a refusal.
2. Fixed: both VM scripts and the fixture.
3. Fixed: the use case buttons in Help first leave the download browser, guide and terminal.
4. Fixed. The same check over the other languages found no second case.
5. Fixed: Aiuto in Italian, the Help mention in English, the card's name in all translations, the tab in `#help-flutter` in all 8. Also found: the new German, Spanish, French, Italian, Dutch and Portuguese text addressed the reader formally, unlike the rest of those manuals; now informal.

## Round 2 (Antigravity, 2026-11-01, commit 2d04819)

1. **Low** `docs/manual/manual.pt.html:281`, `docs/manual/manual.fr.html:464` Two sentences touched by the formal-to-informal change mix both forms of address in the same sentence/paragraph:
   - `docs/manual/manual.pt.html:281` (`#health`): `Uma atualização só começa quando clica em <b>Atualizar</b> (vê <a href="#smart-updates">Atualizações encontradas</a>). Para que serve a tua configuração...` leaves `quando clica` (formal) right before `(vê ...)` and `a tua configuração` (informal `quando clicas`).
   - `docs/manual/manual.fr.html:464` (`#update-running-flutter`): `Quand tu cliques sur <b>Mettre à jour</b> ... <b>Annuler</b> laisse tout en l’état ; laissez l’agent terminer et mettez à jour plus tard.` changes `Quand vous cliquez` to `Quand tu cliques` while leaving `laissez ... mettez` (`laisse ... mets`) in the next sentence of the same paragraph.

### Answers (Claude)
1. Fixed: Portuguese `clicas`. French line 464 is back to its original text: my replace had reached a formal paragraph outside this task. The Dutch "uw opstelling" named in round 2's brief was already fixed in 2d04819.
