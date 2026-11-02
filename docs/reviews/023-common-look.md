# Review: 023-common-look

## Round 1 (Antigravity, 2026-11-02, commit 6fe2ba4)

### 1. `SettingsView`: terminal, screenshot and window/frame-rate rows are grouped into the wrong section cards, and `Map lights` is indented `16 px`

- **Where**: `flutter_app/lib/settings_view.dart:591-715`, `flutter_app/lib/settings_view.dart:836-910`, `flutter_app/lib/settings_view.dart:1105-1130`, `flutter_app/lib/settings_view.dart:1143-1186`
- **What goes wrong**:
  1. `_sections` (`settings_view.dart:1143-1186`) groups every widget after a `_Heading(title)` into that `SectionCard` until the next `_Heading`. After `_Heading(tr('Local LLMs'))` (`settings_view.dart:836`) and `Start local LLMs with their agents` (`line 837`), there is no `_Heading` before `Terminal tabs above the map` (`line 849`), `F9 saves a screenshot` (`line 862`), and `Screenshots go to` (`line 875`). All three are placed inside the **Local LLMs** card under the `"Local LLMs"` title.
  2. After `_Heading(tr('Theme'))` (`settings_view.dart:591`), `Window` (`line 604`), `Corners` (`line 638`), and `Map light frame rate` (`line 685`) have no `_Heading` before them and keep their old inter-section `const SizedBox(height: 24)` gaps (`lines 603, 637, 684`), so `Map light frame rate` sits inside the **Theme** card while `Map lights` is in the **Map** card (`line 1110`).
  3. In the **Map** card, `DropdownButtonFormField` for `Map lights` (`settings_view.dart:1105-1130`) still has `padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)`, which previously aligned it with Material's default `16 px` `CheckboxListTile` padding above it. Because `_sections` now wraps every card body in `ListTileTheme(contentPadding: EdgeInsets.zero)` (`lines 1164-1165`), all other controls in the **Map** card sit at `x = 0` inside the card while `Map lights` is indented `16 px` inward on both sides.
- **How to reproduce**:
  1. Open **Settings**.
  2. Look at the **Theme** card: it includes `Map light frame rate` at the bottom and `24 px` gaps between controls.
  3. Scroll to the **Local LLMs** card: `Terminal tabs above the map`, `F9 saves a screenshot`, and `Screenshots go to` appear inside the **Local LLMs** card.
  4. Scroll to the bottom of the **Map** card: the `Map lights` dropdown is narrower and indented `16 px` from the left and right edges compared to the checkboxes and dropdowns above it.

### 2. `WindowHeader`, `ActionRulesWindow` and `SettingsView`: header and column-width rows crush text or overflow at narrow widths (`420 px`) and in longer translations

- **Where**: `flutter_app/lib/app_look.dart:45-76`, `flutter_app/lib/action_rules_window.dart:346-378`, `flutter_app/lib/settings_view.dart:114-140`
- **What goes wrong**:
  1. `WindowHeader` (`app_look.dart:45-76`) puts `Expanded(child: Column(title, subtitle))` and `[...actions, TextButton.icon('Back')]` in a single non-wrapping `Row`. In `ActionRulesWindow` (`action_rules_window.dart:346-378`), when `_before != null` (after clicking `Restore defaults`), the right side of the `Row` holds `Undo` (`TextButton`), `Restore defaults` (`OutlinedButton`), and `Back` (`TextButton.icon`) plus three `8 px` gaps. At the minimum window width of `420 px` (`OverlayWindow` width `336 px` at `80%`, or `404 px` when dragged to `OverlayWindow._minimum`, leaving `308–376 px` inside `WindowHeader`), those three buttons take `~332 px` in English and over `400 px` in French (`"Annuler"` + `"Rétablir les valeurs par défaut"` + `"Retour"`) or German (`"Rückgängig"` + `"Standard wiederherstellen"` + `"Zurück"`). The `Row` either overflows on the right or leaves `0–40 px` for `Expanded`, crushing `"What may be done"` and its 90-character subtitle into a 1-character-per-line vertical strip dozens of lines tall.
  2. In `SettingsView._columnWidthRows` (`settings_view.dart:114-140`), each row places `Expanded(child: Text(...))` beside two fixed `SizedBox(width: 150)` text fields and two `12 px` gaps (`324 px` fixed width). Inside the **Map** `SectionCard` at a `420 px` window width (`420 - 32 (ListView) - 24 (SectionCard) - 2 (border) = 362 px` inner width), `Expanded` gets only `38 px`, crushing `"MCP servers and skills"` into a narrow multi-line column.
- **How to reproduce**:
  1. Resize the window to its `420 px` minimum width (or switch language to French/German), open **Settings › What may be done**, and click **Restore defaults**: the header buttons crush the title/subtitle into a vertical strip of single letters or overflow the header on the right.
  2. In **Settings** at `420 px` width, scroll to **Map › Column widths**: `"MCP servers and skills"` is squeezed into `38 px` beside the two `150 px` width fields.

### 3. `SettingsView`: `Back` button in `WindowHeader` is not disabled while `busy` is `true`

- **Where**: `flutter_app/lib/settings_view.dart:558`
- **What goes wrong**: `WindowHeader.onBack` (`app_look.dart:27-28`) is nullable so that `null` greys out `Back` while an operation is running, and `SettingsView` disables all its controls and blocks `Esc`/`Backspace` (`_canGoBack` checks `!_navigationBlocked` at `main.dart:2049`) when `busy` is `true`. However, `SettingsView.build` (`settings_view.dart:558`) passes `onBack: onBack` instead of `onBack: busy ? null : onBack`, leaving the `Back` button clickable while `busy` is `true`.
- **How to reproduce**:
  1. Open **Settings** and trigger an action that sets `busy = true` (such as undoing a change under **Recent changes** or running an update).
  2. While the controls in Settings are greyed out, the **Back** button at the top right remains enabled and closes Settings when clicked.

### 4. `ActionRulesWindow`: opening from Ask AI stacks two `Colors.black54` barriers and misaligns the two `OverlayWindow` cards; the test card and its answer are hidden below the fold; borderless pickers without labels hide which part is a control

- **Where**: `flutter_app/lib/main.dart:573-577`, `flutter_app/lib/action_rules_window.dart:135-156, 190-235, 279-334, 340-416`, `flutter_app/lib/overlay_window.dart:81-100`
- **What goes wrong**:
  1. **Double barrier and protruding Ask AI card underneath**: When `Ask AI` (`map_smart_card.dart:1998`) is open, it already renders an `OverlayWindow` with `ModalBarrier(color: Colors.black54)` (`overlay_window.dart:81`) inside `Scaffold.body` (below the `56 px` `AppBar`). Clicking the rules button (`smart-rules`, `map_smart_card.dart:2061`) calls `_openRules` (`main.dart:573-577`), which calls `showDialog` on `_navigator` (spanning the full window including the `AppBar`) and builds `ActionRulesWindow`, which wraps itself in a second `OverlayWindow` (`action_rules_window.dart:340`) with its own `ModalBarrier(color: Colors.black54)`. The map is dimmed twice by two `Colors.black54` barriers, the `AppBar` is dimmed unlike in other `OverlayWindow`s, and because `ActionRulesWindow` is centred in the full window (`H / 2`) while `Ask AI` is centred in `Scaffold.body` (`H / 2 + 28`), `Ask AI`'s bottom edge sticks out below `ActionRulesWindow` (by `4.2 px` at default height, by `28 px` whenever `OverlayWindow._high` has been resized, and around the sides while dragging `ActionRulesWindow`'s resize handles).
  2. **Test card and its answer below the scroll fold**: `Test a request` (`action_rules_window.dart:401-413`) is now at the bottom of the scrollable `ListView` instead of pinned at the bottom of the window. With the 8 `defaultRules()`, the `ListView` content is `~750 px` tall, so in a standard `1280×720` or `1000×700` window `Test a request` starts off-screen. When the user scrolls down until the `Test` button (`rule-test`) is just visible at the bottom of the viewport and clicks `Test`, `_answer` (`lines 407-410`) is inserted below `_tester()` inside the `ListView` without scrolling, so the result renders below the visible viewport and clicking `Test` appears to do nothing until the user scrolls down again.
  3. **Rows without underlines or labels**: `_picker` (`action_rules_window.dart:144`) removes the dropdown underline (`DropdownButtonHideUnderline`) in 4-column rows (`_row` at `lines 190-235` and `_tester` at `lines 279-334`) that have no column headers, borders, or field labels and use blank `Spacer()`s for inactive columns. A default `Connect` rule renders as `Connect   ▾ | All   ▾ | [blank] | All   ▾ | ×` and `Test a request` renders as `Disconnect   ▾ | Skills   ▾ | All   ▾ | All   ▾ | [Test]`, with nothing showing what each `"All"` dropdown controls or where each control's hit area begins and ends.
- **How to reproduce**:
  1. On the map, open **Ask AI** on any column and click the **What may be done** icon (`smart-rules`): the background darkens a second time (`ModalBarrier` in both `OverlayWindow`s) and the bottom of the Ask AI card protrudes below the rules window (resize the rules window to see Ask AI stick out `28 px` below or behind it).
  2. In a `1000×700` window with default rules, open **What may be done**, scroll down just until the **Test** button is visible at the bottom, and click **Test**: `"Allowed: ..."` is added below the fold and is not visible without scrolling again.
  3. Look at the `Connect` rule row or the `Test a request` row: two unlabelled, underline-free `"All"` dropdowns appear in the same row with no indication that one is category/item and the other is agent.

### 5. `TaskHost` and `TaskReview`: duplicate `titleLarge` headings in 7 review windows and duplicate `Back` / `Close` buttons

- **Where**: `flutter_app/lib/task_card.dart:47-53, 94-105`, `flutter_app/lib/performance_view.dart:221-225, 339`, `flutter_app/lib/api_key_review.dart:41-45`, `flutter_app/lib/item_details_view.dart:23-24, 65`, `flutter_app/lib/agent_security_view.dart:68-73, 239`, `flutter_app/lib/connections_view.dart:511-512`, `flutter_app/lib/help_view.dart:167-168, 220`, `flutter_app/lib/main.dart:485, 1705-1711`
- **What goes wrong**:
  1. `TaskHost` (`task_card.dart:47-51`) renders `WindowHeader(title: spec.title)` in `text.titleLarge`, and `TaskReview` (`task_card.dart:98-99`) renders `?title` immediately below it in the scroll view (plus an unconditional `const SizedBox(height: AppSpace.lg)` even when `title == null`, creating `24 + 16 = 40 px` of top padding above `content`). Seven callers pass the same title to both `_cardReview` and `TaskReview.title`: `PerformanceView`, `ApiKeyReview`, `ItemDetailsView`, `AgentSecurityView`, `ConnectionReview`, `HelpView`, and `_updateAllAddons`, displaying the same large heading twice at the top of the window.
  2. Read-only `TaskReview` windows (`ItemDetailsView` at `item_details_view.dart:65` with a primary `FilledButton('Close')`, `PerformanceView` at `performance_view.dart:339`, `AgentSecurityView` at `agent_security_view.dart:239`, `HelpView` at `help_view.dart:220`, and `_taskResult` at `main.dart:485`) show `Back` at the top right of `WindowHeader` and `Close` at the bottom right of `WindowFooter` for the same action.
- **How to reproduce**:
  1. Press **F1** to open **Help** (or open an MCP server's details on the map, an agent's **Security settings**, **API key**, or a provider's **Performance**): the window shows `"Help"` (or the respective title) in `titleLarge` in `WindowHeader` and immediately repeats the same heading below the divider, with `Back` at the top right and `Close` at the bottom right.

### 6. `CardThemeData` in `app_theme.dart`: cards inside cards blend into their parent card, dummy `MapGroupCard` draws a solid border under its dashed border, and `_ThemePreview` blends into `ThemeChoices`

- **Where**: `flutter_app/lib/app_theme.dart:55-76, 117-128, 199-204`, `flutter_app/lib/providers_view.dart:104, 218, 225`, `flutter_app/lib/runtime_details_card.dart:104, 128`, `flutter_app/lib/health_card.dart:78`, `flutter_app/lib/map_groups.dart:54-62`
- **What goes wrong**:
  1. **Cards inside cards have the same `surfaceContainerLow` colour and `0` elevation**: `CardThemeData` (`app_theme.dart:69-76`) gives every `Card` `color: colors.surfaceContainerLow` and `elevation: 0`—identical to `SectionCard` (`app_look.dart:140`). In **Settings › Theme**, the three `ThemeChoices` `Card`s (`app_theme.dart:117`) sit inside the **Theme** `SectionCard` with the exact same `surfaceContainerLow` fill and `0` elevation; inside each `ThemeChoices` card, `_ThemePreview` (`app_theme.dart:199-204`) paints its preview rectangle with `colors.surface` (which in M3 light/dark differs from `surfaceContainerLow` by only ~3% luminance and has no border), so the preview box barely contrasts with the card. Likewise, in **Providers and models** (`providers_view.dart:104, 218, 225`), each local runtime `Card` (`surfaceContainerLow`, `elevation: 0`) contains `RuntimeDetailsCard` (`runtime_details_card.dart:104, 128`) and `HealthCard` (`health_card.dart:78`), which are also `Card`s with `surfaceContainerLow` and `elevation: 0`.
  2. **Dummy `MapGroupCard` gets a solid border underneath its dashed border**: When `group.dummy` is `true`, `MapGroupCard` (`map_groups.dart:54-62`) paints `_DashedBorder(colors.outline, corners(context))` over a `Card` that does not set `shape`. Because `CardThemeData` now sets `side: BorderSide(color: colors.outlineVariant)` on every `Card`, empty category cards draw a continuous solid `outlineVariant` border underneath the dashed border.
  3. **Desktop background vs `surfaceContainerLow`**: When `mode == 'system'` and `desktop['background']` is present (`app_theme.dart:55-60`), `appTheme` overrides `colors.surface` with `background` but leaves `colors.surfaceContainerLow` at the seed-generated colour, so `Card` and `SectionCard` (now `elevation: 0`) do not derive their surface from the desktop background and can have almost no contrast against a dark desktop `background` close to `#191c1b`.
- **How to reproduce**:
  1. Open **Settings › Theme**: the three `System` / `Light` / `Dark` cards have the same `surfaceContainerLow` background as the **Theme** section card around them, and the `Light` preview rectangle in light mode (or `Dark` in dark mode) has almost no contrast against its card.
  2. Open **Providers and models** with an installed local LLM (e.g. `llama.cpp`): the `RuntimeDetailsCard` and `HealthCard` inside the provider card have the same `surfaceContainerLow` fill and `0` elevation as the outer provider card.
  3. On the map with an empty category (dummy `MapGroupCard`), look at its border: a solid `outlineVariant` border is drawn continuously under the dashed border.

### Answers (Claude)
1. Fixed. The old flat Settings list put these rows under the wrong headings already; the cards made it visible. Window, corners and frame rate have their own card, terminals and screenshots an untitled one, Map lights sits flush, and the old 24 px gaps are 12.
2. Fixed. Below 640 px the header puts its actions under the title; the column-width rows put their fields under the column's name below 480 px.
3. Fixed: Back waits while Settings is busy.
4. Fixed. The Ask AI window closes before the rules open, so one shade and one window. The test card is pinned under the list. Each field has an outline and its label (Action, Category, Item, Agent, translated); a field is made anew when its value changes.
5. Fixed. A review leaves out a title that repeats its window's header. Help, details, security, performance and task results have no Close at the bottom: Back in the header leads out.
6. Fixed. Cards in a card (theme choices, a provider's details and health) are one step stronger, the theme preview has an outline, the empty category card has only its dashed border, and with the desktop's colours the card tones step from its background.


## Round 2 (Antigravity, 2026-11-02, commit ef9199f)

CLEAN
