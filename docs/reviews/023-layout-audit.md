# Layout audit (Antigravity, 2026-11-02, commit 332a94f)

## 1. Where the app's screens, windows, cards and controls differ

### 1.1 Window containers, sizes and outer padding

The app currently has six different ways to host a secondary view or dialog:

| Host pattern | Where used | Outer margin / size | Inner padding | Chrome |
| --- | --- | --- | --- | --- |
| `OverlayWindow` + `TaskHost` (`overlay: true`) | `main.dart:236-263`, `overlay_window.dart:14-69`, `task_card.dart:11-57` | `margin: EdgeInsets.all(24)`, `ConstrainedBox(maxWidth: 760, maxHeight: 620)` | `TaskHost` adds `Padding(all: 16)` around header and body | Scrim `colorScheme.scrim.withAlpha(110)`, `Material(elevation: 8, color: surfaceContainerHigh, shape: cardTheme.shape ?? rounded(12))` |
| `TaskHost` as full page (`_viewHost`) | `main.dart:257-263` (`FirstAgentView`, `ConnectionsView`, `ProvidersView`, `ModelBrowser`, `_groupFocus`) | Full body area | `Padding(all: 16)` (`task_card.dart:22`) | None (sits directly in `Scaffold.body`) |
| Standalone side page (`SettingsView`, `AgentDetailsView`, `AgentListView`) | `settings_view.dart:152-160`, `agent_details_view.dart:112-120`, `agent_list_view.dart:41-84` | Full body area | `SettingsView`: header `fromLTRB(8, 8, 8, 0)`, list `all(16)`; `AgentDetailsView`: `ListView(padding: all(16))`; `AgentListView`: search `all(12)` | None |
| `OverlayWindow` without `TaskHost` | `main.dart:4707-4732` (`AgentTerminalView`), `action_rules_window.dart:111-189` (`ActionRulesWindow` inside `showDialog`) | `margin: EdgeInsets.all(24)`, `maxWidth: 760, maxHeight: 620` | `AgentTerminalView`: toolbar `symmetric(horizontal: 8, vertical: 6)` (`agent_terminal.dart:225`); `ActionRulesWindow`: `Padding(all: 20)` (`action_rules_window.dart:116`) | `OverlayWindow` card; when opened via `showDialog` (`main.dart:1443-1447`), `showDialog`'s barrier stacks a second dark scrim under `OverlayWindow`'s own scrim (`overlay_window.dart:33`) |
| Custom floating card (`_SmartAskDialog`) | `map_smart_card.dart:955-1009` | `Dialog` with `insetPadding: all(24)`, `ConstrainedBox(maxWidth: 520, maxHeight: 560)` | `Padding(fromLTRB(16, 12, 12, 14))` (`map_smart_card.dart:973`) | Custom `Container` with `colorScheme.surface`, `cardRadius(context)` (fallback `14`), `Border.all(outlineVariant.withValues(alpha: 0.45))`, `BoxShadow(blurRadius: 24, offset: (0, 10))` |
| Material `AlertDialog` / `Dialog` / `ModalBottomSheet` | 21 call sites across 13 files (listed in §1.10) | Material default (`SizedBox(width: 360..520)` or unconstrained) | Material default (`24` content padding) | Material dialog surface; bypasses `OverlayWindow` and `TaskHost` |

### 1.2 Header height, title style, and Back / Close button placement

Headers are built differently across windows and pages:

- **`TaskHost` (`task_card.dart:24-45`)**:
  - Back button on the **left** (`TextButton.icon` with `Icons.arrow_back` and `tr('Back')`) when `onClose != null && !overlay` (`task_card.dart:26-31`).
  - Title uses `Theme.of(context).textTheme.titleMedium` (`task_card.dart:34`).
  - Close button on the **right** (`TextButton` with `tr('Close')`, no icon) when `onClose != null && overlay` (`task_card.dart:38-43`).
  - Bottom gap below header is `SizedBox(height: 12)` (`task_card.dart:46`), with no divider.
- **`SettingsView` (`settings_view.dart:155-184`)**:
  - Wrapped in `Padding(fromLTRB(8, 8, 8, 0))` instead of `16`.
  - Back button on the **left** (`TextButton.icon` with `Icons.arrow_back`, `tr('Back')`), followed by `SizedBox(width: 8)`.
  - Title uses `titleMedium` (`settings_view.dart:168`).
  - Right action is an `OutlinedButton.icon` (`Icons.undo`, `iconSize: 16`) for Undo (`settings_view.dart:173-181`).
  - Followed by `const Divider(height: 16)` (`settings_view.dart:185`).
- **`ActionRulesWindow` (`action_rules_window.dart:121-137`)**:
  - Surrounded by `Padding(all: 20)` (`action_rules_window.dart:116`).
  - Title on the left uses `titleMedium` (`action_rules_window.dart:124`).
  - Close button on the right is `TextButton(child: Text(tr('Close')))` (`action_rules_window.dart:131-135`).
  - Followed by `SizedBox(height: 4)` above subtitle text, then `SizedBox(height: 12)` (`action_rules_window.dart:138-143`).
- **`_SmartAskDialog` (`map_smart_card.dart:976-995`)**:
  - Leading `SmartStatusIcon(size: 16)` + `SizedBox(width: 8)` (`map_smart_card.dart:977-978`).
  - Title uses `titleSmall?.copyWith(fontWeight: FontWeight.w600)` (`map_smart_card.dart:982-984`) instead of `titleMedium`.
  - Close button on the right is `IconButton(icon: Icon(Icons.close, size: 18), visualDensity: VisualDensity.compact)` (`map_smart_card.dart:987-994`) instead of `TextButton('Close')`.
  - Followed by `SizedBox(height: 6)` (`map_smart_card.dart:996`).
- **`AgentTerminalView` (`agent_terminal.dart:224-273`)**:
  - Custom toolbar `Padding(symmetric(horizontal: 8, vertical: 6))` with `TextButton.icon(Icons.arrow_back, tr('Back'))` on the left even when shown inside `OverlayWindow` (`main.dart:4707-4732`), title in `titleSmall` (`agent_terminal.dart:238`), followed by `Divider(height: 1)` (`agent_terminal.dart:274`).
- **`AgentDetailsView` (`agent_details_view.dart:122-145`)**:
  - Inside the scrollable `ListView(padding: all(16))` rather than a fixed top bar; `Back` `TextButton.icon` sits in an inline `Row` above a separate `Text(agent['name'], style: headlineSmall)` (`agent_details_view.dart:146-149`).
- **Views that support both `hosted: true` and `hosted: false`**:
  - `FirstAgentView` (`first_agent_view.dart:42-55`), `ConnectionsView` (`connections_view.dart:159-189`), `ProvidersView` (`providers_view.dart:80-108`), and `ModelBrowser` (`provider_task_dialog.dart:227-240`) each contain their own fallback header (`headlineSmall` in `FirstAgentView`, `ConnectionsView`, `ProvidersView`; `titleMedium` + `TextButton('Close')` in `ModelBrowser`) in addition to `_viewHost`'s `TaskHost` header.
  - Because `_viewHost` eats the top bar, `ConnectionsView` puts its `Undo` button in a separate `Row` below the `TaskHost` header (`connections_view.dart:169-179`), and `FirstAgentView` puts its `Refresh` `IconButton` in a separate right-aligned `Row` below the `TaskHost` header (`first_agent_view.dart:56-65`).
- **`MapGroupCard` header (`map_groups.dart:262-336`)**:
  - `Padding(fromLTRB(10, 8, 6, 6))`, `Icon(size: 16)`, title `fontSize: 12, fontWeight: FontWeight.w600`, count badge (`fontSize: 11, fontWeight: FontWeight.w600`), optional `_HeaderButton` (`24×24`, `Icon(size: 15)`), followed by `Divider(height: 1, thickness: 1)` (`map_groups.dart:338-341`).
- **`MapWelcome` banner (`map_welcome.dart:51-139`)**:
  - `Padding(fromLTRB(12, 8, 12, 0))` outside, `Padding(fromLTRB(14, 10, 10, 10))` inside, title `titleSmall`, `IconButton(Icons.close, size: 18, visualDensity: VisualDensity.compact)`.

### 1.3 Footer and action button placement & button kinds (`TextButton`, `FilledButton`, `OutlinedButton`, `IconButton`)

- **`TaskReview` (`task_card.dart:78-115`)**:
  - Footer uses `Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end)` below `SizedBox(height: 12)` (`task_card.dart:107-112`).
  - Most callers pass `[TextButton(Cancel), FilledButton(Apply/Continue/Install/Update)]` (`main.dart:307-316`, `main.dart:510-519`, `main.dart:1330-1339`, `main.dart:1833-1842`, `main.dart:3385-3394`, `main.dart:4467-4475`).
  - `main.dart:3227-3252` (`_smartProvider` local/cloud prompt) puts two `FilledButton`s and one `OutlinedButton` in `actions`, with `Cancel` on the **left** as a `TextButton` (`main.dart:3228-3230`) instead of consistent Cancel/Primary order.
  - `main.dart:3675-3724` (`_openProblems`) puts `FilledButton.tonal` / `OutlinedButton` at the **left** of the `TaskReview.actions` list and `TextButton('Close')` at the **right** (`main.dart:3719-3722`), duplicating `TaskHost`'s own top-right `Close` button.
  - `addon_details.dart:43-59` (`AddonDetails`) and `item_details_view.dart:145-169` (`ItemDetailsView`) put a second `TextButton(tr('Close'))` in the bottom-right `TaskReview.actions` even though `TaskHost` already renders `Close` in the top-right header.
- **`ConnectionAuthoring` (`connection_authoring.dart:303-317`) and `ProviderConnectionsDialog` (`provider_connections.dart:192-207`)**:
  - Put `TextButton('Cancel')` and `FilledButton('Review changes')` at the **bottom-left** of the scrollable `ListView` (`Row` with default `MainAxisAlignment.start`, `SizedBox(width: 8)`), instead of bottom-right pinned below the scroll view like `TaskReview`.
- **`FoundOnPcView` (`found_on_pc_view.dart:175-183`)**:
  - Puts `FilledButton('Connect selected')` at the **bottom-left** (`Align(alignment: Alignment.centerLeft)`) inside the scroll view.
- **`FirstAgentView` (`first_agent_view.dart:245-261`)**:
  - Puts `FilledButton` + `OutlinedButton` in a left-aligned `Wrap(spacing: 8, runSpacing: 8)` inside the card.
- **`_SmartAskDialog` (`map_smart_card.dart:1239-1285`, `1349-1371`, `1374-1410`)**:
  - Custom button rows: `FilledButton.tonalIcon` (`iconSize: 16`) for Ask AI / Make a plan, `FilledButton.icon` for Apply, `TextButton` for New question / Edit, aligned left with `Spacer()` pushing helper dropdown to the right.
- **`MapWelcome` (`map_welcome.dart:121-135`, `167-194`)**:
  - Uses `FilledButton.tonal` (`visualDensity: VisualDensity.compact`) and `TextButton` (`visualDensity: VisualDensity.compact`).
- **Destructive confirmation buttons**:
  - `model_removal_dialog.dart:73-79`: `FilledButton` with `FilledButton.styleFrom(backgroundColor: colorScheme.error, foregroundColor: colorScheme.onError)`.
  - `agent_action_dialog.dart:54-56`, `main.dart:1563-1565`, `main.dart:2572-2575`: default `FilledButton` (primary accent colour) for uninstall / remove / delete actions.

### 1.4 Paddings and spacing steps

- **Page / window outer padding**:
  - `16`: `TaskHost` (`task_card.dart:22`), `SettingsView` list (`settings_view.dart:187`), `AgentDetailsView` (`agent_details_view.dart:118`), `ConnectionsView` (`connections_view.dart:164`), `ProvidersView` (`providers_view.dart:85`), `FirstAgentView` (`first_agent_view.dart:39`).
  - `20`: `ActionRulesWindow` (`action_rules_window.dart:116`).
  - `16, 12, 12, 14`: `_SmartAskDialog` (`map_smart_card.dart:973`).
  - `12`: `AgentListView` search box (`agent_list_view.dart:45`), `main.dart:4270` migration error.
  - `24`: `OverlayWindow` margin (`overlay_window.dart:40`), `_SmartAskDialog` insetPadding (`map_smart_card.dart:960`), `AlertDialog` default padding.
- **Card internal padding**:
  - `EdgeInsets.all(16)`: `CostCard` (`cost_card.dart:19`), `HealthCard` (`health_card.dart:27`), `ProjectsCard` (`projects_card.dart:48`), `RuntimeDetailsCard` (`runtime_details_card.dart:25`), `AgentDetailsView` cards (`agent_details_view.dart:141, 314, 417`), `ProvidersView` runtime card (`providers_view.dart:201`).
  - `EdgeInsets.all(12)`: `FirstAgentView` cards (`first_agent_view.dart:71, 211`), `ConnectionsView` cards (`connections_view.dart:210`), `McpCatalogView` (`mcp_catalog_view.dart:71`), `SkillsWebView` (`skills_web_view.dart:61`), `FoundOnPcView` (`found_on_pc_view.dart:80`), `HelpView` (`help_view.dart:119, 134`).
  - `EdgeInsets.symmetric(horizontal: 12, vertical: 8)`: `ActionRulesWindow` rule card (`action_rules_window.dart:200`), `SettingsView` helper/change cards (`settings_view.dart:842`).
  - `EdgeInsets.fromLTRB(10, 8, 10, 10)`: `_SmartAskDialog` inner boxes (`map_smart_card.dart:1203, 1291`).
  - `EdgeInsets.fromLTRB(8, 8, 8, 8)`: `MapGroupCard` body (`map_groups.dart:351`).
- **Vertical gaps between sections/cards**:
  - `SizedBox(height: 16)`: `SettingsView` before section titles (`settings_view.dart:821`).
  - `SizedBox(height: 12)`: `AgentDetailsView` (`agent_details_view.dart:183, 187, 198, 210`), `ConnectionsView` (`connections_view.dart:190`), `ProvidersView` (`providers_view.dart:120, 145`), `TaskHost` (`task_card.dart:46`), `TaskReview` (`task_card.dart:106`).
  - `SizedBox(height: 10)`: `_SmartAskDialog` (`map_smart_card.dart:1173, 1238, 1286`), `MapAddonsFocus` (`map_addons_focus.dart:128`).
  - `SizedBox(height: 8)`: `FirstAgentView` (`first_agent_view.dart:165`), `HelpView` (`help_view.dart:69, 128`).
  - `SizedBox(height: 6)` / `4`: `ActionRulesWindow` (`action_rules_window.dart:138, 183`), `SettingsView` (`settings_view.dart:206, 391`).

### 1.5 Icon sizes

- `13`: `_SmartCardBox` chevron (`map_smart_card.dart:512`), `MapLegendButton` icon (`map_legend.dart:27`).
- `14`: `MapEditor` box badges/buttons (`map_editor.dart:1395, 1995, 2236, 2274, 2407`), `_SmartCardBox` row icon (`map_smart_card.dart:576, 616`), `TerminalTabs` close (`terminal_tabs.dart:114`).
- `15`: `MapGroupCard._HeaderButton` (`map_groups.dart:462`), `MapZoomBar` (`map_zoom.dart:86`).
- `16`: `MapGroupCard` header icon (`map_groups.dart:284`), `SmartStatusIcon` default (`map_smart_card.dart:444`), `SettingsView` undo icon (`settings_view.dart:175`), `ProvidersView` icons (`providers_view.dart:169, 439`), `ConnectionsView` undo (`connections_view.dart:173`).
- `18`: `main.dart` AppBar `SmartStatusIcon` (`main.dart:4237`), `_SmartAskDialog` close (`map_smart_card.dart:988`), `MapWelcome` close (`map_welcome.dart:108`), `ActionRulesWindow` delete (`action_rules_window.dart:239`), `AgentDetailsView` copy/edit (`agent_details_view.dart:245`), `TerminalTabs` status (`terminal_tabs.dart:82`).
- `20`: `AgentDetailsView` security/folder icons (`agent_details_view.dart:330`), `McpToolsView` (`mcp_tools_view.dart:78`).
- `24` (Material default): `main.dart` AppBar `IconButton`s (`main.dart:4224, 4245, 4252, 4260`), `TextButton.icon(Icons.arrow_back)` across headers.

### 1.6 Corner radii (`cardRadius(context)` vs hard-coded `BorderRadius.circular(...)`)

`app_theme.dart:85-103` defines `cornerRadius(...)` and `cardRadius(context)` so Settings › Corners (`sharp` = 0, `round` = 12, `window` = Hyprland rounding) controls the whole app. Several files ignore `cardRadius(context)` and hard-code radii:

- **Follow `cardRadius(context)` / `cardTheme.shape`**:
  - `app_theme.dart:152-177` (`CardThemeData`, `DialogThemeData`, `PopupMenuThemeData`, `InputDecorationTheme`).
  - `overlay_window.dart:46-50` (`cardTheme.shape` fallback `12`).
  - `map_groups.dart:226` (`MapGroupCard`: `cardRadius(context)`).
  - `map_editor.dart:775, 1138, 1280, 1875, 2116` (`cardRadius(context)` / `(cardRadius(context) - 2).clamp(0, 10)`).
  - `map_smart_card.dart:468, 965` (`(cardRadius(context) - 2).clamp(0, 10)` and `cardRadius(context)`).
- **Hard-coded radii that ignore Settings › Corners**:
  - `settings_view.dart:1009, 1068`: `BorderRadius.circular(6)` on `_ThemeColors` preview chip and `_ColorPick` swatches (`borderRadius: BorderRadius.circular(6)`).
  - `map_smart_card.dart:1204, 1292, 1326`: `BorderRadius.circular(10)` and `BorderRadius.circular(8)` on `_SmartAskDialog` answer box, plan box, and diff container.
  - `map_welcome.dart:54`: `BorderRadius.circular(10)` on the Welcome banner container.
  - `map_zoom.dart:33, 74`: `BorderRadius.circular(8)` and `BorderRadius.circular(6)` on the zoom bar and its buttons.
  - `map_legend.dart:21, 90`: `BorderRadius.circular(6)` and `BorderRadius.circular(10)` on the legend button and popup card.
  - `map_groups.dart:303, 452`: `BorderRadius.circular(8)` on the count pill and `BorderRadius.circular(5)` on `_HeaderButton`.
  - `map_addons_focus.dart:111, 215, 286, 360`: `BorderRadius.circular(12)`, `BorderRadius.circular(8)`, `BorderRadius.circular(999)` on focus cards and badges.
  - `terminal_tabs.dart:64`: `BorderRadius.circular(6)` on terminal tab pills.
  - `agent_list_view.dart:123`: `BorderRadius.circular(999)` on status pills.
  - `providers_view.dart:362, 567`: `BorderRadius.circular(4)` and `BorderRadius.circular(6)` on status/tag badges.
  - `connections_view.dart:550`: `BorderRadius.circular(6)` on badges.
  - `mcp_catalog_view.dart:115`: `BorderRadius.circular(6)` on badges.

### 1.7 Card and section styles

- **Map group cards (`MapGroupCard`, `map_groups.dart:224-358`)**:
  - `Container` with `colorScheme.surfaceContainerLow`, border `outlineVariant.withValues(alpha: 0.45)` (or custom border colour when `borderOn`), header band + `Divider(height: 1, thickness: 1)` + body.
- **Material `Card` (default `Card()`)**:
  - Used in `AgentDetailsView`, `CostCard`, `HealthCard`, `ProjectsCard`, `RuntimeDetailsCard`, `ProvidersView`, `ConnectionsView`, `FirstAgentView`, `HelpView`, `ActionRulesWindow`, `SettingsView` (for helper/change rows).
  - In `app_theme.dart:152-155`, `CardThemeData` sets `shape: RoundedRectangleBorder(borderRadius: radius)` and `clipBehavior: Clip.antiAlias`, with no border and default Material elevation/surface tint.
- **Settings sections (`SettingsView`, `settings_view.dart:187-880`)**:
  - Flat `ListView` with bold `titleSmall` section headings (`_sectionTitle`, `settings_view.dart:819-830`), raw `SwitchListTile` (`contentPadding: EdgeInsets.zero`), raw `Row` (`_dropdownRow`, `_colorRow`, `_sliderRow`) with no card grouping and no divider between sections.
- **Bordered `Container` boxes (`_SmartAskDialog`, `MapWelcome`, `MapAddonsFocus`)**:
  - Hand-rolled `BoxDecoration(color: surfaceContainerLow / surfaceContainerHighest, borderRadius: ..., border: Border.all(outlineVariant...))`.

### 1.8 Dividers

- `Divider(height: 1, thickness: 1, color: scheme.outlineVariant.withValues(alpha: 0.35))`: `MapGroupCard` header separator (`map_groups.dart:338-341`).
- `const Divider(height: 1)`: `AgentTerminalView` (`agent_terminal.dart:274`), `TerminalTabs` (`terminal_tabs.dart:36`), `AgentSecurityView` (`agent_security_view.dart:123`).
- `const Divider(height: 16)`: `SettingsView` below top bar (`settings_view.dart:185`).
- `const Divider(height: 24)`: `AgentDetailsView` (`agent_details_view.dart:366`), `ConnectionsView` (`connections_view.dart:317`), `ItemDetailsView` (`item_details_view.dart:72`).
- `const Divider()` (default `height: 16`): `RuntimeDetailsCard` (`runtime_details_card.dart:123`), `ProvidersView` (`providers_view.dart:288`).
- `const VerticalDivider(width: 1)`: `main.dart:4695`, `MapZoomBar` (`map_zoom.dart:54` `Container(width: 1, height: 16)`).
- No divider under header: `TaskHost` (`task_card.dart:46`), `ActionRulesWindow` (`action_rules_window.dart:138`), `_SmartAskDialog` (`map_smart_card.dart:996`).

### 1.9 Hard-coded text sizes, weights and font families (instead of theme `textTheme`)

- `map_groups.dart:293-297`: `TextStyle(fontSize: 12, fontWeight: FontWeight.w600)` (group card title).
- `map_groups.dart:310-314`: `TextStyle(fontSize: 11, fontWeight: FontWeight.w600)` (group card count badge).
- `map_groups.dart:382-386`: `TextStyle(fontSize: 11, fontWeight: FontWeight.w600)` (`MapSubgroupLabel`).
- `map_editor.dart:1367, 1380, 1412, 1924, 1938, 1966, 2009, 2170, 2195, 2248, 2286`: `fontSize: 12`, `fontSize: 11`, `fontSize: 10`, `fontWeight: FontWeight.w600 / w500` across map boxes, badges, and toolbars.
- `map_smart_card.dart:495, 505, 583, 623, 636, 1213, 1301, 1334`: `fontSize: 11.5`, `fontSize: 11`, `fontSize: 12`, `fontFamily: 'monospace'` in smart card rows and `_SmartAskDialog`.
- `map_legend.dart:32, 102, 135`: `fontSize: 12`, `fontSize: 11`, `fontWeight: FontWeight.w600`.
- `map_zoom.dart:50`: `fontSize: 11, fontWeight: FontWeight.w600`.
- `map_addons_focus.dart:80, 144, 155, 222, 293, 305, 367`: `fontSize: 14`, `fontSize: 13`, `fontSize: 12`, `fontSize: 11`, `fontWeight: FontWeight.w600`.
- `terminal_tabs.dart:91`: `fontSize: 12`.
- `settings_view.dart:1022`: `fontSize: 12` inside `_ThemeColors`.
- `providers_view.dart:367, 572`: `fontSize: 11`, `fontSize: 12` on status/tag badges.
- `agent_list_view.dart:128`: `fontSize: 11` on status pill.
- `installer_review.dart:57`, `api_key_review.dart:72`, `item_details_view.dart:108`, `addon_details.dart:34`, `agent_terminal.dart:312`: `fontFamily: 'monospace'`, `fontSize: 12` / `13` inline instead of a shared monospace text style.

### 1.10 Hard-coded colours not from `ColorScheme` / theme extensions

- **Status / traffic / health colours duplicated across files**:
  - `map_smart_card.dart:447-453` (`SmartStatusIcon`): `Color(0xFFD97706)` (amber), `Color(0xFF2E7D32)` / `Color(0xFF66BB6A)` (green).
  - `terminal_tabs.dart:74-80`: `Colors.amber`, `Colors.green`, `Colors.grey`.
  - `agent_list_view.dart:115-120`: `Colors.green`, `Colors.orange`, `Colors.grey` with `.withValues(alpha: 0.15)`.
  - `providers_view.dart:356-360`: `Colors.green`, `Colors.orange`, `Colors.grey`.
  - `health_card.dart:49-55`: `Colors.red`, `Colors.orange`, `Colors.green`.
  - `mcp_tools_view.dart:75-77`: `Colors.green`, `Colors.red`, `Colors.orange`.
  - `settings_view.dart:792-798`: `Colors.green`, `Colors.orange`, `Colors.red` for MCP check status icons.
- **Map & palette colours**:
  - `settings_view.dart:980-991`: `_swatches` palette (`0xFF3584E4`, `0xFF2EC27E`, `0xFFE5A50A`, `0xFFE66100`, `0xFFDC143C`, `0xFF9141AC`, `0xFF6E7781`) and `Colors.white` / `Colors.black` check icon (`settings_view.dart:1083`).
  - `map_editor.dart:56-102` and `map_lights.dart:45-95`: line kind colours (purple, blue, teal, amber, red, green) for dark/light mode.

### 1.11 Dialogs (`AlertDialog` / `Dialog` / `ModalBottomSheet`) that bypass `OverlayWindow` / `TaskHost`, or the reverse

Currently `main.dart` has a clean in-window overlay system (`_card` + `_host` -> `OverlayWindow` + `TaskHost` + `TaskReview`), yet 21 places still call Flutter's `showDialog` or `showModalBottomSheet`:

1. **`ActionRulesWindow` (`main.dart:1443-1447`, `action_rules_window.dart:111`)**:
   - Opened via `showDialog(builder: (_) => ActionRulesWindow(...))`, and `ActionRulesWindow.build` wraps itself in `OverlayWindow` (`action_rules_window.dart:111`). This stacks two modal barriers (`showDialog`'s barrier + `OverlayWindow`'s scrim) and uses `Navigator.pop(context)` instead of the app's overlay system or a standard dialog route.
2. **`_AddRuleDialog` (`action_rules_window.dart:250-356`)**:
   - Opens a nested `AlertDialog` on top of `ActionRulesWindow` (`action_rules_window.dart:164-169`). If `ActionRulesWindow` lays out the add-rule form inline (or as a section card inside the window), this nested `AlertDialog` disappears completely.
3. **`AgentActionDialog` (`agent_action_dialog.dart:23-60`, called from `main.dart:2520`)**:
   - Uses `AlertDialog` to confirm/configure an agent action, whereas provider and connection confirmations use `_cardReview` (`TaskHost` + `TaskReview`).
4. **`ModelRemovalDialog` (`model_removal_dialog.dart:25-83`, called from `main.dart:1926`)**:
   - Uses `AlertDialog` while the subsequent removal progress runs in `_card`.
5. **`SubagentsDialog` (`subagents_dialog.dart:32-160`, called from `main.dart:2503`)**:
   - Full list/editor of subagents inside an `AlertDialog` (`SizedBox(width: 520, height: 420)`); fits `OverlayWindow` + `TaskHost` much better than a narrow `AlertDialog`.
6. **`PerformanceView` (`performance_view.dart:29-165`, called from `main.dart:1951`)**:
   - Detailed table/metrics view inside an `AlertDialog` (`SizedBox(width: 520)`); belongs in `OverlayWindow` + `TaskHost`.
7. **`ProviderTaskDialog` (`provider_task_dialog.dart:27-196`)**:
   - `AlertDialog` wrapper (`provider_task_dialog.dart:80`); `ModelBrowser` (`provider_task_dialog.dart:199`) already runs hosted inside `_viewHost` (`main.dart:4359`), while `ProviderTaskDialog` is a leftover `AlertDialog`.
8. **`AgentSecurityView` (`agent_security_view.dart:48-200`, called from `agent_details_view.dart:335`)**:
   - Opens a large multi-section security editor inside an `AlertDialog` (`SizedBox(width: 520)`); should use `OverlayWindow` + `TaskHost`.
9. **`McpToolsView` (`mcp_tools_view.dart:35-136`, called from `connections_view.dart:445`)**:
   - Opens an MCP server tools inspector in an `AlertDialog` (`SizedBox(width: 500, height: 420)`); should use `OverlayWindow` + `TaskHost`.
10. **`AgentDetailsView` inline dialogs (`agent_details_view.dart:548, 608`)**:
    - Two `AlertDialog`s for editing agent arguments/environment and notes.
11. **`ProvidersView` port/host settings dialog (`providers_view.dart:476-535`)**:
    - `AlertDialog` for editing runtime host/port.
12. **`ConnectionsView` custom MCP server dialog (`connections_view.dart:610-715`)**:
    - `AlertDialog` with multi-field form for adding a custom MCP server.
13. **`MapEditor` dialogs (`map_editor.dart:936, 1528, 1572, 1659`)**:
    - `showModalBottomSheet` (`map_editor.dart:936`) for node actions on narrow screens (the only bottom sheet in a desktop Linux app!) and three `AlertDialog`s (`1528, 1572, 1659`) for link/group/provider picking.
14. **`main.dart` inline `AlertDialog`s (`main.dart:1544, 1581, 2557, 4849`)**:
    - `1544`: confirm removing an agent from a project.
    - `1581`: text input for a new project path.
    - `2557`: confirm stopping a running agent terminal.
    - `4849` (`_ShotNote`): F9 screenshot note dialog.
15. **`_SmartAskDialog` (`map_smart_card.dart:955-1009`)**:
    - Uses `showDialog` with a custom `Dialog` container instead of `OverlayWindow` + `TaskHost`.

### 1.12 SnackBars and banners

- `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(...)))` is called in `main.dart:194, 1463, 1988, 2539, 4059`, `agent_details_view.dart:252, 588`, `settings_view.dart:738`, without a `SnackBarThemeData` in `app_theme.dart` (so it uses Material's default inverse-surface bar without matching `cardRadius(context)`).
- `main.dart:4269-4283` uses a raw `Padding(all: 12)` `Column` for `migration_error`, whereas `main.dart:4285-4295` uses `MaterialBanner` for `_failed`, and `MapWelcome` (`map_welcome.dart:51`) uses a custom bordered `Container`.

---

## 2. Proposal: One small common layout set

### 2.1 Spacing steps (`AppSpace`)

Define one small constant class in `app_theme.dart` (used everywhere instead of ad-hoc `6, 10, 14, 20`):

- `AppSpace.xs = 4.0` — tight inline icon-to-label gap, title-to-subtitle gap.
- `AppSpace.sm = 8.0` — standard gap between buttons, chips, and compact card rows; inner padding of map group cards.
- `AppSpace.md = 12.0` — gap between cards/sections in a list; inner padding of compact cards; gap below a window header or above a window footer.
- `AppSpace.lg = 16.0` — outer padding of every page (`SettingsView`, `ConnectionsView`, `ProvidersView`, `FirstAgentView`, `AgentDetailsView`) and every `OverlayWindow` / `TaskHost`; inner padding of major section cards.
- `AppSpace.xl = 24.0` — outer margin of `OverlayWindow` from the main window edges.

### 2.2 Corner radii (`cardRadius`, `controlRadius`)

In `app_theme.dart`:
- Keep `cardRadius(context)` (`0` sharp, `12` round, or window rounding) for windows, section cards, `MapGroupCard`, banners, and `SnackBarThemeData`.
- Add `double controlRadius(BuildContext context) => (cardRadius(context) - 4).clamp(0.0, 8.0);` for inner boxes, chips, colour swatches, zoom buttons, terminal tabs, and status badges so that **Sharp corners (`0`)** makes inner controls sharp (`0`) too, and **Round corners (`12`)** gives inner controls a consistent `6–8 px` radius.

### 2.3 Text styles by role

Derived in `appTheme()` (`app_theme.dart`) so widgets never hard-code `fontSize` or `fontWeight`:

| Role | Theme getter / helper | Spec | Where used |
| --- | --- | --- | --- |
| **Window / Page Title** | `textTheme.titleMedium` (`w600`) | `16 px`, `FontWeight.w600` | Every `WindowHeader` (pages, `OverlayWindow`, `ActionRulesWindow`, `_SmartAskDialog`) |
| **Section / Group Title** | `textTheme.titleSmall` (`w600`) | `13 px`, `FontWeight.w600` | `AppSectionCard` header, `MapGroupCard` header, Settings section titles |
| **Body** | `textTheme.bodyMedium` | `14 px`, `FontWeight.w400`, `onSurface` | Row labels, descriptions, dialog content |
| **Hint / Secondary** | `textTheme.bodySmall` (`onSurfaceVariant`) | `12 px`, `FontWeight.w400`, `colorScheme.onSurfaceVariant` | Subtitles under row labels, empty-state explanations, secondary metadata |
| **Caption / Badge** | `textTheme.labelSmall` (`w600`) | `11 px`, `FontWeight.w600` | Count pills in `MapGroupCard`, status badges, `MapSubgroupLabel`, zoom percentage |
| **Monospace / Code** | `appMonoStyle(context)` | `12 px`, `fontFamily: 'monospace'`, `onSurface` | Diff previews (`TaskReview`, `_SmartAskDialog`), commands, paths, terminal/log snippets |

### 2.4 Shared widgets to add or consolidate

1. **`WindowHeader` (unifies `TaskHost` top row, `SettingsView` top bar, `ActionRulesWindow` top row, `_SmartAskDialog` top row, `AgentTerminalView` bar)**:
   - **Props**: `String title`, `String? subtitle`, `Widget? leadingIcon`, `List<Widget> actions`, `VoidCallback? onBack`, `VoidCallback? onClose`, `String Function(String) tr`.
   - **Layout**:
     - Left: if `onBack != null`, `TextButton.icon(icon: Icon(Icons.arrow_back, size: 18), label: Text(tr('Back')))` + `SizedBox(width: 8)`.
     - Optional `leadingIcon` (e.g. `SmartStatusIcon(size: 16)`) + `SizedBox(width: 8)`.
     - Title column (`Expanded`): `Text(title, style: textTheme.titleMedium)` and optional `Text(subtitle, style: textTheme.bodySmall)`.
     - Right: `...actions` (e.g. `Undo` `OutlinedButton.icon` or `Refresh` `IconButton`), and if `onClose != null`, `IconButton(icon: const Icon(Icons.close, size: 18), tooltip: tr('Close'), onPressed: onClose)`.
     - Bottom separator: `const Divider(height: 1)` followed by `SizedBox(height: 12)` (or `0` when followed directly by a full-bleed `ListView` with `padding: EdgeInsets.all(16)`).
   - **Rule for Back vs Close**:
     - Full-window side pages (`SettingsView`, `ConnectionsView`, `ProvidersView`, `FirstAgentView`, `ModelBrowser`, `AgentDetailsView`, `_groupFocus`) pass `onBack` -> **Back** button on the **left**.
     - Floating `OverlayWindow`s (`TaskHost(overlay: true)`, `ActionRulesWindow`, `_SmartAskDialog`, `AgentTerminalView` overlay, and converted dialogs) pass `onClose` -> **Close** button on the **right** (and `Esc` dismisses).

2. **`WindowFooter` (unifies `TaskReview` footer, `ConnectionAuthoring` buttons, `ProviderConnectionsDialog` buttons, `AlertDialog.actions`)**:
   - **Layout**: Fixed below the scrollable body, separated by `const SizedBox(height: 12)`, using a `Row` with optional `leading` widget on the left (e.g. helper picker or secondary link) and `Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end)` on the right.
   - **Button kind & order**:
     - Secondary / dismiss action first: `TextButton` (`Cancel`) or `OutlinedButton`.
     - Primary action last (rightmost): `FilledButton` (`Apply`, `Continue`, `Save`, `Add`) or destructive `FilledButton` (`backgroundColor: colorScheme.error, foregroundColor: colorScheme.onError` for `Remove` / `Delete` / `Uninstall`).
     - Never repeat a bottom-right `Close` button when `WindowHeader` already has `onClose`.

3. **`AppSectionCard` (the `MapGroupCard` pattern shared with Settings, side pages, and windows)**:
   - Generalises `MapGroupCard` (`map_groups.dart:224-358`) for use outside the canvas:
   - **Visuals**: `Container` with `decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(cardRadius(context)), border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)))`, `clipBehavior: Clip.antiAlias`.
   - **Header band (optional)**: `Padding(fromLTRB(12, 8, 8, 8))` with optional leading `Icon(size: 16, color: scheme.onSurfaceVariant)`, `Text(title, style: textTheme.titleSmall)`, optional count pill (`Container` with `controlRadius(context)`, `scheme.surfaceContainerHighest`, `textTheme.labelSmall`), and optional trailing header action buttons (`OutlinedButton` / compact `IconButton`), followed by `Divider(height: 1, thickness: 1, color: scheme.outlineVariant.withValues(alpha: 0.35))`.
   - **Body**: `Padding(padding: bodyPadding ?? const EdgeInsets.all(12), child: child)`.
   - `MapGroupCard` keeps its map-specific collapse/drag/measure behaviour while sharing the exact same visual tokens (`surfaceContainerLow`, `0.45` `outlineVariant` border, `0.35` divider, header typography).

4. **`AppSettingRow` (list row with a control at the right)**:
   - Replaces the three separate row helpers in `SettingsView` (`_dropdownRow`, `_colorRow`, `_sliderRow`, plus raw `SwitchListTile`) and row layouts in `ActionRulesWindow`, `ProvidersView`, and `AgentSecurityView`.
   - **Layout**: `Padding(symmetric(vertical: 6))` containing a `Row(crossAxisAlignment: CrossAxisAlignment.center)`:
     - Left (`Expanded`): `Column(crossAxisAlignment: CrossAxisAlignment.start)` with `Text(title, style: textTheme.bodyMedium)` and optional `Padding(top: 2, child: Text(subtitle, style: textTheme.bodySmall))`.
     - Gap: `const SizedBox(width: 12)`.
     - Right: the control (`Switch`, `DropdownButtonHideUnderline` + `DropdownButton`, `Slider`, `FilledButton.tonal`, or colour swatches).
   - Inside an `AppSectionCard`, multiple `AppSettingRow`s can be separated by thin `Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.25))` or `SizedBox(height: 4)`.

5. **Chips, badges and colour swatches (`AppBadge`, `_ColorPick`)**:
   - **`AppBadge`**: `Container` with `padding: symmetric(horizontal: 6, vertical: 2)`, `borderRadius: BorderRadius.circular(controlRadius(context))`, semantic status colours from a small theme helper (`appStatusColor(context, kind)` for `ok` / `warn` / `error` / `neutral`), and `textTheme.labelSmall`.
   - **`_ColorPick` & `_ThemeColors` (`settings_view.dart:1005-1091`)**: Use `BorderRadius.circular(controlRadius(context))` instead of hard-coded `6`, and `textTheme.bodySmall` instead of `fontSize: 12`.

### 2.5 How `SettingsView` and the side pages use them

- **`SettingsView`**:
  - Top bar uses `WindowHeader(title: tr('Settings'), onBack: onBack, actions: [if (changes.isNotEmpty) undoButton])`.
  - Body `ListView(padding: const EdgeInsets.all(AppSpace.lg))` groups related settings into `AppSectionCard`s (Appearance & Theme, AI Map, Terminal & Shortcuts, Background Service & Helpers, MCP Checks, Recent Changes) instead of a single flat ungrouped list.
  - Every row inside each `AppSectionCard` uses `AppSettingRow` (including boolean switches, dropdowns, sliders, and colour rows).
- **Side pages (`ConnectionsView`, `ProvidersView`, `FirstAgentView`, `ModelBrowser`, `_groupFocus`)**:
  - `_viewHost` renders `WindowHeader(title: ..., onBack: ..., actions: ...)` at the top. Page-specific header actions (`Undo` in `ConnectionsView`, `Refresh` in `FirstAgentView`) pass into `WindowHeader.actions` instead of occupying an extra row below the header.
  - Content cards inside those pages use `AppSectionCard` with `AppSpace.md` (`12 px`) vertical gaps between cards.
- **Dialogs -> `OverlayWindow` + `TaskHost`**:
  - Convert `ActionRulesWindow`, `_SmartAskDialog`, `SubagentsDialog`, `PerformanceView`, `AgentSecurityView`, `McpToolsView`, `AgentActionDialog`, and `ModelRemovalDialog` to render inside `OverlayWindow` + `TaskHost` (with `WindowHeader` and `WindowFooter`), eliminating double scrims and inconsistent `AlertDialog` sizing.

---

## 3. Concrete new layout for `ActionRulesWindow`

`ActionRulesWindow` (`flutter_app/lib/action_rules_window.dart`) should be opened without stacking `showDialog`'s barrier on top of `OverlayWindow`'s scrim (or hosted via `TaskHost(overlay: true)`), and should replace its nested `_AddRuleDialog` `AlertDialog` with an inline `AppSectionCard` inside the window so the user can see existing rules while adding a new one.

### Text sketch

```text
+--------------------------------------------------------------------------+
|  OverlayWindow (margin: 24, maxWidth: 760, maxHeight: 620, cardRadius)   |
|  Padding: EdgeInsets.all(16)                                             |
|                                                                          |
|  WindowHeader                                                            |
|  [ Rules for actions (titleMedium, w600)                        [×] ]    |
|  [ Set what agents may do without asking... (bodySmall, variant)    ]    |
|  ──────────────────────────────────────────────────────────────────────  |
|  ↕ 12 px                                                                 |
|                                                                          |
|  Expanded ScrollView (ListView, children gap: 12 px)                     |
|  +--------------------------------------------------------------------+  |
|  | AppSectionCard: "Add rule"                                         |  |
|  | Header: [ + (16px)  Add rule (titleSmall, w600) ]                  |  |
|  | ────────────────────────────────────────────────────────────────── |  |
|  | Body (padding: 12):                                                |  |
|  |   AppSettingRow:                                                   |  |
|  |     Action (bodyMedium)             [ Dropdown: Run command ▾ ]    |  |
|  |   AppSettingRow:                                                   |  |
|  |     Decision (bodyMedium)           [ Dropdown: Ask each time ▾ ]  |  |
|  |   AppSettingRow:                                                   |  |
|  |     Pattern (bodyMedium)            [ TextField: e.g. git status ] |  |
|  |     Optional match pattern (bodySmall)                             |  |
|  |   ↕ 8 px                                                           |  |
|  |   Row (alignment: end):                         [ + Add (Filled) ] |  |
|  +--------------------------------------------------------------------+  |
|                                                                          |
|  +--------------------------------------------------------------------+  |
|  | AppSectionCard: "Active rules"                                     |  |
|  | Header: [ Shield (16px)  Active rules (titleSmall)   ( 3 ) badge ] |  |
|  | ────────────────────────────────────────────────────────────────── |  |
|  | Body (padding: 0, divided rows):                                   |  |
|  |   (When _rules is empty, padding 16:)                              |  |
|  |     "No rules yet. Default rules apply." (bodySmall, variant)      |  |
|  |                                                                    |  |
|  |   Row 1 (padding: horizontal 12, vertical 8):                      |  |
|  |     Column (Expanded):                                             |  |
|  |       "Run command · git *" (bodyMedium, w500)                     |  |
|  |     [ Allow (AppBadge, ok) ]  [ Dropdown ▾ ]  [ 🗑 IconButton 18 ] |  |
|  |   ──────────────────────────────────────────────────────────────── |  |
|  |   Row 2 (padding: horizontal 12, vertical 8):                      |  |
|  |     Column (Expanded):                                             |  |
|  |       "Write file · /etc/*" (bodyMedium, w500)                     |  |
|  |     [ Deny (AppBadge, err) ]  [ Dropdown ▾ ]  [ 🗑 IconButton 18 ] |  |
|  +--------------------------------------------------------------------+  |
|                                                                          |
|  ↕ 12 px                                                                 |
|  WindowFooter                                                            |
|  [                                                    [ Close (Text) ] ] |
+--------------------------------------------------------------------------+
```

### Key improvements in `ActionRulesWindow`:
1. **No double scrim or nested `AlertDialog`**: Adding a rule happens in the top `AppSectionCard` ("Add rule") directly inside the window, and `_AddRuleDialog` (`action_rules_window.dart:250-356`) is removed.
2. **Same header, padding (`16`), and section card chrome as the rest of the app**: Uses `WindowHeader` (`titleMedium` + `bodySmall` subtitle + `Divider(height: 1)`) and `AppSectionCard` (`surfaceContainerLow`, `cardRadius(context)`, `0.45` `outlineVariant` border) matching `MapGroupCard`.
3. **Structured rule rows**: Each rule row uses `AppSettingRow` proportions (`padding: symmetric(horizontal: 12, vertical: 8)`), shows a clear decision badge (`Allow` / `Ask` / `Deny` via `AppBadge`), inline decision `DropdownButton`, and a compact `18 px` delete `IconButton`.

---

## 4. Ordered work steps (each leaving the app usable, most visible first)

1. **Step 1 — Shared layout primitives in `app_theme.dart` and `task_card.dart`**:
   - Add `AppSpace`, `controlRadius(context)`, `appMonoStyle(context)`, `appStatusColor(context, ...)`, and `SnackBarThemeData` in `app_theme.dart`.
   - Upgrade `TaskHost` and `TaskReview` in `task_card.dart` into the shared `WindowHeader` (supporting `actions`, `subtitle`, `leadingIcon`, `Divider(height: 1)`) and `WindowFooter` (removing duplicate bottom `Close` buttons in `ItemDetailsView`, `AddonDetails`, and `_openProblems`).
   - Add `AppSectionCard`, `AppSettingRow`, and `AppBadge` (either in `task_card.dart` or a small `app_widgets.dart` imported by views).

2. **Step 2 — Rebuild `ActionRulesWindow` with the shared primitives**:
   - Replace `ActionRulesWindow`'s custom `Padding(all: 20)` layout and nested `_AddRuleDialog` with `TaskHost(overlay: true)` / `WindowHeader`, two `AppSectionCard`s ("Add rule" and "Active rules"), and `AppSettingRow` rows.
   - Fix how `main.dart:1443` opens `ActionRulesWindow` so it does not stack two dark scrims.

3. **Step 3 — Align `SettingsView` and the side pages (`ConnectionsView`, `ProvidersView`, `FirstAgentView`, `AgentDetailsView`)**:
   - Give `SettingsView` the shared `WindowHeader`, group its controls into `AppSectionCard`s, and replace `_dropdownRow`, `_colorRow`, `_sliderRow`, and raw `SwitchListTile`s with `AppSettingRow`.
   - Move `ConnectionsView`'s `Undo` button and `FirstAgentView`'s `Refresh` button into `_viewHost` / `WindowHeader.actions`, and align `ConnectionAuthoring`, `ProviderConnectionsDialog`, and `FoundOnPcView` action buttons with `WindowFooter`.

4. **Step 4 — Align `_SmartAskDialog`, `AgentTerminalView` overlay, and `MapWelcome`**:
   - Update `_SmartAskDialog` (`map_smart_card.dart`) to use `OverlayWindow` + `WindowHeader` (`titleMedium`), `cardRadius(context)` / `controlRadius(context)` on inner answer/plan/diff boxes, and `appMonoStyle(context)`.
   - Update `AgentTerminalView` (`agent_terminal.dart`) and `MapWelcome` (`map_welcome.dart`) to use `cardRadius(context)` / `controlRadius(context)` and the shared header/button styles.

5. **Step 5 — Convert the remaining `AlertDialog`s and `showModalBottomSheet`, and clean up hard-coded radii/fonts/colours**:
   - Convert `SubagentsDialog`, `PerformanceView`, `AgentSecurityView`, `McpToolsView`, `AgentActionDialog`, `ModelRemovalDialog`, and `MapEditor`'s dialogs/bottom sheet to `OverlayWindow` + `TaskHost`.
   - Replace remaining hard-coded `BorderRadius.circular(...)` (`map_zoom.dart`, `map_legend.dart`, `terminal_tabs.dart`, `map_addons_focus.dart`, `providers_view.dart`, `agent_list_view.dart`) with `cardRadius(context)` / `controlRadius(context)` and status colours with `appStatusColor`.
