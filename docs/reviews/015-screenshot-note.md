# Review: 015-screenshot-note

## Round 1 (Antigravity, 2026-11-01, commit fec7b2a)

1. **`flutter_app/lib/settings_view.dart:104-107` (and `flutter_app/test/map_editor_test.dart:1636-1656`) — Settings › Map reads and writes `column_widths` and `column_defaults`, while the map and both cores use `widths` and `defaults`**
   - **What goes wrong:** In `SettingsView._columnWidthRows()` (`flutter_app/lib/settings_view.dart:83-125`), the two fields per column read and update `layout['column_widths']` and `layout['column_defaults']` (`lines 104-107`). However, `MapLayout._columnWidthFor` (`flutter_app/lib/map_layout.dart:30`), `MapEditor._dragColumn` / `_resetColumn` (`flutter_app/lib/map_editor.dart:601, 613`), `valid_layout` (`flutter_map_editor.py:45-46`), and `validLayout` (`packages/maprisma_core/lib/src/settings.dart:115-116`) all read and write `layout['widths']` and `layout['defaults']`, and both `valid_layout` and `validLayout` strip any other keys when `settings.update` saves `flutter_map_layout`. As a result:
     1. Dragging a column on the map never shows its width under **Settings › Map › Column widths** (`Current width` stays empty).
     2. Typing a `Current width` or `Default width` in **Settings › Map** never changes the column's width on the map or its double-click default, and the value is discarded when `_saveMapLayout` writes `flutter_map_layout` through `settings.update` (`flutter_app/lib/main.dart:225-227`).
   - **How to reproduce:**
     1. Drag a column border on the map to widen **Agents**, then open **Settings › Map**: the **Agents** `Current width` field is still empty (`Automatic`).
     2. Enter `410` in `Current width` (or `340` in `Default width`) for **Agents** and press Enter, then return to the map: the **Agents** column is still `266` px wide, double-clicking its border does not use `340`, and reopening **Settings** after a refresh shows both fields empty again because `valid_layout` / `validLayout` dropped `column_widths` and `column_defaults`.

2. **`flutter_app/lib/settings_view.dart:960-992` — `_WidthField` loses an unsubmitted edit when the user leaves Settings (e.g. clicking `← Back` or a header button)**
   - **What goes wrong:** `_WidthFieldState` applies its text only from `onSubmitted` (`line 1006`) or from `_focus.addListener` when `!_focus.hasFocus` (`lines 962-964`). On desktop, clicking `← Back` (`TextButton.icon` at `lines 399-403`) or a header navigation button unmounts `SettingsView` without moving focus to another widget first, and `FocusNode.dispose()` (`line 989`) detaches the node without notifying listeners. Any width typed into a `_WidthField` without pressing Enter or clicking another focusable control first is never passed to `onChanged`.
   - **How to reproduce:** Open **Settings › Map**, click into a column's `Current width` or `Default width` field, type `360` (without pressing Enter), and click **← Back**. The edit is silently discarded.

3. **`docs/manual/manual.fr.html:1058, 1354`, `docs/manual/manual.pt.html:1024, 1315`, and `translations/pt.json:3256, 3261` (`flutter_app/assets/translations/pt.json:117, 122`) — inconsistent form of address (`tu` instead of `vous` / `você`) and wrong Settings name (`Paramètres` / `Definições` instead of `Réglages` / `Configurações`)**
   - **What goes wrong:**
     - **French (`docs/manual/manual.fr.html:1058, 1354`):** Section `flutter-map-editor` (`lines 1054-1060`) and the rest of the French manual address the reader with `vous` (`Glissez un agent… Sélectionnez… Repliez… déplacez… utilisez… choisissez… ouvrez…`) and call Settings `Réglages` (`Réglages › <b>Carte</b>` on `line 1060`, `<td>Réglages</td>` on `line 1355`, matching `"Settings": "Réglages"` in `translations/fr.json`). The new paragraph at `line 1058` switches to `tu` (`Fais glisser le bord gauche ou droit…`) and writes `Paramètres › Carte` right above `Réglages › <b>Carte</b>` on `line 1060`. The updated `F9` shortcut row at `line 1354` also uses `tu` and `paramètres` (`Dans les paramètres, tu peux choisir un autre dossier`) right above `<td>Réglages</td>` on `line 1355`.
     - **Portuguese (`docs/manual/manual.pt.html:1024, 1315`; `translations/pt.json:3256, 3261`; `flutter_app/assets/translations/pt.json:117, 122`):** Section `flutter-map-editor` (`lines 1020-1026`), the rest of `manual.pt.html`, and the map editor's existing strings in `translations/pt.json` address the reader in the 3rd person (`você`: `Arraste… Selecione… Recolha… escolha… abra… ative…`) and call Settings `Configurações` (`Configurações › <b>Mapa</b>` on `line 1026`, `<td>Configurações</td>` on `line 1316`, matching `"Settings": "Configurações"` in `translations/pt.json`). The new paragraph at `manual.pt.html:1024` switches to 2nd-person `tu` (`Arrasta a margem esquerda ou direita…`) and writes `Em Definições › Mapa` right above `Configurações › <b>Mapa</b>` on `line 1026`. Likewise, `manual.pt.html:1315` (`Podes acrescentar uma nota. Nas definições podes escolher outra pasta.`) and `translations/pt.json:3256, 3261` (`"…com uma nota se quiseres. Num terminal, usa o símbolo da câmara."`, `"Arrasta uma margem para mudar a largura; duplo clique restaura-a"`) use `tu` (`quiseres`, `usa`, `Arrasta`, `Podes`, `podes`) and `definições`.
   - **How to reproduce:** Inspect `docs/manual/manual.fr.html` at `#flutter-map-editor` (`lines 1057-1060`) and `#shortcuts` (`lines 1354-1355`), `docs/manual/manual.pt.html` at `#flutter-map-editor` (`lines 1023-1026`) and `#shortcuts` (`lines 1315-1316`), or switch the app language to Portuguese and check the column-border tooltip and the **Settings › Map › Screenshot key (F9)** subtitle.

### Answers (Claude)
1. Not a defect: Settings, `MapLayout`, `MapEditor` and both validators all use `column_widths` and `column_defaults`. The keys `widths` and `defaults` and `_columnWidthFor` do not exist at fec7b2a.
2. Fixed: a width typed but not applied is applied when the field goes away. `scan_settings_test.dart` covers it, along with showing a saved width and keeping pins.
3. Fixed: the new French and Portuguese texts in the manuals and the app, including the camera sentence from 013 in both manuals, now use `vous` and `você`, with `Réglages` and `Configurações`. Older strings in `fr.json` and `pt.json` with `tu` stay as they are.

## Round 2 (Antigravity, 2026-11-01, commit ba41799)

1. **`flutter_app/lib/settings_view.dart:84-93, 986-1005` (and `flutter_app/test/scan_settings_test.dart:42-57`) — A `_WidthField` saving at `dispose()` can re-send an already applied value and overwrite another field's change with its older copy of `layout`**
   - **What goes wrong:**
     1. `_WidthFieldState._apply()` (`flutter_app/lib/settings_view.dart:986-996`) calls `widget.onChanged(next)` when `next != widget.value?.round()`, and `dispose()` (`lines 999-1005`) checks the same condition (`valid && next != widget.value?.round()`) without recording that `_apply()` already sent `next`. If `SettingsView` is unmounted before rebuilding with the new `widget.value` (for example, when a field submits or blurs in the same frame that `SettingsView` closes, or when a caller does not rebuild `SettingsView` on `onMapLayout`), `dispose()` schedules a duplicate `changed(next)` post-frame callback for that field.
     2. In `SettingsView._columnWidthRows()` (`flutter_app/lib/settings_view.dart:84-93`), `change` constructs `{...Map<String, dynamic>.from(layout), list: widths}` from the `layout` snapshot captured when `SettingsView.build` last ran. When two fields' callbacks run without an intervening rebuild (or when a later field in tree order re-fires in `dispose()`), the later callback overwrites the earlier field's change with its older copy of `layout`.
     3. This happens directly in `flutter_app/test/scan_settings_test.dart:42-57`: after submitting `'5000'` in `column_defaults-models` and typing `'360'` in `column_widths-agents`, unmounting `SettingsView` disposes `column_widths-agents` first (`layouts[1]` has `'column_widths': {'agents': 360}` without `'column_defaults'`) and `column_defaults-models` second (`layouts[2]` re-sends its older `layout` with `'column_widths': {'agents': 410}`, overwriting `layouts.last['column_widths']['agents']` back to `410`).
   - **How to reproduce:** Run `flutter test test/scan_settings_test.dart` and inspect `layouts.last` at `flutter_app/test/scan_settings_test.dart:51-57`: `layouts.last['column_widths']['agents']` is `410` instead of `360` because `column_defaults-models` fired again in `dispose()` with its stale `layout`. Likewise, in the app, if an earlier width field loses focus and `_apply()` runs in the same frame that `SettingsView` is unmounted while a later width field disposes with an unapplied edit (or vice versa), the second callback's older `layout` copy overwrites the first field's change.


### Answers (Claude)
1. Fixed at the cause: `onMapLayout` now takes a change, which `main.dart` applies to the latest layout, so a field no longer sends a copy of it. A repeated save writes the same value again and changes nothing else. `scan_settings_test.dart` is strict again: both values survive, and my loose check from ba41799 is gone.

New in this commit, by Uwe's request: Settings › Map can draw a border around the category cards, with thickness and colour.

## Round 3 (Antigravity, 2026-11-01, commit 9a4512a)

1. **`flutter_app/lib/settings_view.dart:158-160` — `Border thickness` `DropdownButtonFormField` uses a constant key with `initialValue`, so it does not update when `border['width']` changes externally**
   - **What goes wrong:** `DropdownButtonFormField<int>` in `_cardBorderRows` (`flutter_app/lib/settings_view.dart:158-169`) sets `key: const ValueKey('card-border-width')` and `initialValue: border['width'] as int? ?? 1`. Because `FormField` only reads `initialValue` in `FormFieldState.initState()`, the dropdown keeps its initial state when `settings['flutter_map_layout']['card_border']['width']` changes while `SettingsView` stays mounted (unlike every other `DropdownButtonFormField` in `flutter_app/lib/settings_view.dart` at lines `258`, `341`, `398`, `506`, `542`, `573`, `898`, `1046`, `1069`, `1092`, which include the current value in their `ValueKey`).
   - **How to reproduce:** Pump `SettingsView` with `flutter_map_layout: {'card_border': {'on': true, 'width': 2}}`, then rebuild `SettingsView` with `flutter_map_layout: {'card_border': {'on': true, 'width': 5}}` (or let `_refreshTheme()` in `flutter_app/lib/main.dart:889-896` reload an updated setting while Settings is open): the **Border thickness** dropdown still displays `2 px` instead of `5 px`.


### Answers (Claude)
1. Fixed: the dropdown's key carries the current width, like the other dropdowns in Settings. `scan_settings_test.dart` rebuilds Settings with another width and expects it to show.

## Round 4 (Antigravity, 2026-11-01, commit 6093d1e)

CLEAN

