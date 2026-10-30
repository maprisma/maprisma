# 004 Smart Card — GUI Design Proposal

Author: Antigravity (GUI) · Core counterpart: Claude · Target: `flutter_app/`

---

## Core Design Principle: Step-by-Step, One Decision per Screen

To keep user handling effortless and the visual layout clean on both Linux and future macOS builds:
1. **Few controls per step:** Never mix prompt input, candidate lists, and connection options on the same view. Each step shows one clear question or up to 3 choices, with at most two buttons at the bottom (`Close` / `Back` on the left, primary action on the right).
2. **Adding an item and connecting it to an agent are separate (connection is optional):**
   - Just like **MCP servers** and **skills**, a **model** or **provider** can be installed/downloaded on its own without being connected to an agent first.
   - **Step A** installs or downloads the item (model, provider, agent, MCP server, or skill).
   - **Step B (optional)** — only after Step A finishes (or when the user explicitly asked to connect): a clean follow-up offers **`Skip`** or **`Connect to <Agent>…`** (which opens the normal `ConnectionReview` with Undo). The user can always skip and connect later by dragging a line on the map.
3. **All 4 columns get a Smart card at the top:**
   - Column `0`: `MCP servers and skills`
   - Column `1`: `Agents`
   - Column `2`: `Providers`
   - Column `3`: `Models`

---

## 1. Placement, Collapsed & Open Look, and Column Reordering

### Where it sits in each column
Every column `col` (`0..3`) sits at `left = 16 + col * 302` (`width: 266`). Top-to-bottom stack:
1. **`MapGroupCard`** (`top: 0, height: 98, width: 266`) — category summary card.
2. **`MapSmartCard`** (`top: 106, width: 266`) — always pinned at the top of its column directly below `MapGroupCard` (never reorderable below group cards). Collapsed height is `38` (`corners(context)` radius, `surfaceContainerHigh`, `outlineVariant` 1 px border).
3. **`MapCardLayout` group cards** (`top: 156` when `smart_helpers` is non-empty, `144` when hidden) — stacked strictly inside their column at `left = 16 + col * 302`.

### Column-only group card reordering with drop separator (no free 2D card dragging)
- Group cards (`MapCardLayout`) **cannot** be dragged outside their category column (`saved['cards']` free `[x, y]` positions and the 30 px `Move left` / `Move right` / `Move up` / `Move down` menu items are removed).
- Dragging a group card's 36 px header vertically reorders it **within its own column only** (`saved['card_order']`):
  - While dragging (`onVerticalDragUpdate`), `MapEditor` computes the target insertion index (`0..columnCards.length`) in that column — always below `MapSmartCard` (`y >= 156`) — and draws a **2 px `colors.primary` horizontal drop separator line** (`left: 16 + col * 302, width: 266`, with 4 px end-caps) in the 18 px gap between the two cards where it will land.
  - Releasing (`onVerticalDragEnd`) commits the new `card_order` for that column.
  - The card header menu keeps only `Earlier card` (`before`) and `Later card` (`after`) within the same column.

### Why the map never jumps when a Smart card opens
- **Fixed layout slot + overlay expansion:** `MapLayout` reserves a constant 38 px header slot (`top: 106..144`) whenever Smart cards are visible. Opening or closing a Smart card **never** recomputes `MapLayout` node `boxes`, `cards`, `curves`, or `MapLayout.size`, and **never** mutates `_aiTransform` (`TransformationController`).
- **Outside `MapStaticCache`, inside `InteractiveViewer`:** Placed in the board `Stack` *after* `MapStaticCache` and `MapLightLayer`. Typing, step transitions, or progress indicators do not invalidate `MapStaticCache`.
- **Expanded overlay:** When open, `MapSmartCard` expands downward from `top: 106` up to `maxHeight: 320` as an elevated `Card` (`elevation: 4`, `surfaceContainerHigh`, 1.5 px `primary` border) over that column. Only one column's Smart card is open at a time.
- **Zoom, pan, scroll, and Omarchy popup (`1100 × 760`):** Scales and pans with the canvas; absorbs pointer gestures inside the open card so scrolling/selecting text never drags the map; at `maxHeight: 320` (`y = 106..426`) it fits cleanly inside the 760 px Omarchy popup.

---

## 2. Step-by-Step Flow & Sketches (Few Controls per Step)

```text
Collapsed (top: 106, height: 38, width: 266)
┌──────────────────────────────────────────┐
│ ✦ Ask AI… · Qwen 2.5 (local)         [▾] │
└──────────────────────────────────────────┘
```

```text
Step 1 — Ask (open, idle)
┌──────────────────────────────────────────┐
│ ✦ Ask AI · Models                    [▴] │
├──────────────────────────────────────────┤
│ Qwen 2.5 (Ollama) · Local, no tokens [▾] │
│ ┌──────────────────────────────────────┐ │
│ │ Find an image-capable model for      │ │
│ │ Ollama                               │ │
│ └──────────────────────────────────────┘ │
│                         [Close]  [Ask ↵] │
└──────────────────────────────────────────┘
```

```text
Step 1b — Working
┌──────────────────────────────────────────┐
│ ✦ Ask AI · Models                    [▴] │
├──────────────────────────────────────────┤
│ "Find an image-capable model for Ollama" │
│ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ Qwen 2.5 is checking Models…             │
│                                 [Cancel] │
└──────────────────────────────────────────┘
```

```text
Step 2a — Clarify (only when needed; 1 question, click a chip to answer)
┌──────────────────────────────────────────┐
│ ✦ Ask AI · Models                    [▴] │
├──────────────────────────────────────────┤
│ i Which local LLM should run this model? │
│                                          │
│   ( Ollama )   ( llama.cpp )             │
│                                          │
│ [← Back]                         [Close] │
└──────────────────────────────────────────┘
```

```text
Step 2b — Choose a Candidate (at most 3, one button per candidate)
┌──────────────────────────────────────────┐
│ ✦ Ask AI · Models                    [▴] │
├──────────────────────────────────────────┤
│ PC: 12 GB VRAM · 32 GB RAM · 84 GB free  │
│ ┌──────────────────────────────────────┐ │
│ │ llama3.2-vision:11b · 7.9 GB         │ │
│ │ ✓ Fits in VRAM · Vision + chat       │ │
│ │                             [Review] │ │
│ └──────────────────────────────────────┘ │
│ ┌──────────────────────────────────────┐ │
│ │ llava:7b · 4.7 GB                    │ │
│ │ ✓ Fits in VRAM · Smaller & faster    │ │
│ │                             [Review] │ │
│ └──────────────────────────────────────┘ │
│ [← Back]                         [Close] │
└──────────────────────────────────────────┘
```

```text
Step 3 — Review & Install/Download (existing TaskHost half-card)
┌──────────────────────────────────────────┐
│ Download llama3.2-vision:11b?            │
│                                          │
│ Runtime       Ollama                     │
│ Download      7.9 GB                     │
│ This PC       ✓ Fits in 12 GB VRAM       │
│                                          │
│                    [Cancel]   [Download] │
└──────────────────────────────────────────┘
```

```text
Step 4 — Optional Connect (shown in Smart card only after install/download
         when connecting to an agent makes sense; always skippable)
┌──────────────────────────────────────────┐
│ ✦ Ask AI · Models                    [▴] │
├──────────────────────────────────────────┤
│ ✓ llama3.2-vision:11b is ready.          │
│ Connect it to an agent now? (Optional)   │
│                                          │
│   ( Claude Code )   ( OpenCode )         │
│                                          │
│                                   [Done] │
└──────────────────────────────────────────┘
  (Clicking an agent chip opens the standard ConnectionReview with Undo;
   clicking Done leaves the model unconnected in the column.)
```

---

## 3. All 12 States

| State | Condition | Controls on screen |
|---|---|---|
| **1. Hidden (no agent ready)** | `smart_helpers` in `map.snapshot` is empty. | None (`top` stays `144`). |
| **2. Collapsed (default)** | Ready helper exists; card closed. | 1 bar (`✦ Ask AI… · <Helper>`), click/Enter to open. |
| **3. Idle (Step 1: Ask)** | Card open, waiting for request. | Helper line (dropdown if >1), text field, `Close`, `Ask`. |
| **4. Working (Step 1b)** | `map.smart_ask` task running. | Progress bar, status text, `Cancel`. |
| **5. Clarifying question (Step 2a)** | `status == 'clarify'`. | Question text, 2–4 choice chips (tap one to continue), `← Back`, `Close`. |
| **6. Helpful refusal / redirect** | `status == 'redirect'` (wrong column or unsupported). | Explanation of what works instead, optional `Move to <Column>` button (pre-fills that column's Smart card), `← Back`, `Close`. |
| **7. Proposal (Step 2b: Choose)** | `status == 'proposal'` (1–3 candidates). | PC limits line (when relevant), 1–3 candidate cards each with one `Review` button, `← Back`, `Close`. Kept if the user cancels Step 3. |
| **8. Review (Step 3)** | User clicked `Review` on a candidate. | Existing `TaskHost` half-card (`InstallerReview`, `AgentActionReview`, `ConnectionReview`, `SkillWebReview`, `McpCatalogReview`, or `SmartModelDownloadReview`): just the facts + `Cancel` / primary button. |
| **9. Running** | User confirmed Step 3. | Existing `TaskProgress` card with progress bar and `Cancel`. |
| **10. Done / Optional Connect (Step 4)** | Step 3 completed. | Config changes light up top-bar **Undo** (`connections.undo`). If a newly added model, provider, MCP server, or skill is not yet connected to an agent, the Smart card offers optional agent chips (`Connect to an agent now?`) + `Done`. |
| **11. Error** | `status == 'error'` or RPC error. | Error text, `Try again` (returns to Step 1 with text kept), `Close`. |
| **12. Agent out of tokens** | `status == 'out_of_tokens'`. | Message `"{0} has reached its usage or token limit."`, `Ask {1} instead` (if a second helper is ready), `Close`. |

---

## 4. Proposal Content per Column

| Column | What the AI can propose (from real search / catalog results only) | Step 3 Review Widget | Step 4 Optional Connect |
|---|---|---|---|
| **`MCP servers and skills`** (`mcp`) | 1. Recommended or registry MCP server (`mcp.catalog` / `mcp.search`)<br>2. Web skill (`skills.web_search`)<br>3. Connect an existing MCP server or skill folder to an agent | `McpOptionReview` / `SkillWebReview` / `ConnectionReview` | If added without agents (or for one agent), optional chip to connect to an agent via `connections.preview`. |
| **`Agents`** (`agents`) | 1. Install, update, or remove an agent (`agents.action_preview` / `installers.preview`)<br>2. Lower/raise a security setting (`agents.security_preview`)<br>3. Connect an agent to an existing provider, model, MCP server, or skill | `AgentActionReview` / `InstallerReview` / `ConnectionReview` | After installing an agent, optional chip to connect it to an installed provider. |
| **`Providers`** (`providers`) | 1. Install a local LLM runtime (`Ollama`, `llama.cpp`, `KoboldCpp`, `Jan`) with core-checked GPU build (`ROCm`, `Vulkan`, `CUDA`, `CPU`)<br>2. Change a runtime tuning setting (`models.tuning_preview`)<br>3. Connect a provider to an agent | `InstallerReview` / `ConnectionReview` | After installing a local runtime, optional chip to connect it to an agent. |
| **`Models`** (`models`) | 1. Download a GGUF file or pull an Ollama model from real search results (`models.search` / `models.files`), with core-computed size & PC fit (`✓ Fits in VRAM`, `! Uses RAM offload`, `✕ Too large for this PC`)<br>2. Attach/switch/remove an installed model (`models.attach_preview`, `models.switch_preview`, `models.remove_preview`) | `SmartModelDownloadReview` / `ConnectionReview` / `ModelRemovalDialog` | After downloading a model, optional chip to connect it to an agent (`models.attach_preview` / `connections.preview`) — completely optional! |

---

## 5. Which Agent Answers: Choice & Setting

- **Default from existing settings:**
  1. Confirmed **local helper** (`ai_local_helper`) first (`command: 'local-helper'`, `local: true`, `"Local, no tokens"`).
  2. Otherwise **AI checks agent** (`ai_checks_agent`) first (`local: false`, `"Uses plan/tokens"`), followed by other installed, signed-in agents with a guarded start.
- **In the card:** One compact line at the top of Step 1 shows `<Helper name> · Local, no tokens` (or `Uses plan/tokens`), acting as a dropdown when multiple helpers are ready. Persistent default stays in **Settings**.

---

## 6. What the GUI Needs from the Core (`routes.json` Draft)

1. **`map.snapshot` (existing route — add `"smart_helpers"` to `result`):**
   ```json
   "smart_helpers": [
    {
     "command": "string",
     "local": "bool",
     "name": "string"
    }
   ]
   ```

2. **`map.smart_ask` (new route in `routes.json`):**
   `column` is one of `'mcp' | 'agents' | 'providers' | 'models'`.

```json
  "map.smart_ask": {
   "area": "map",
   "kind": "read",
   "note": "Starts a worker task; tasks.status returns the checked proposal, question or redirect.",
   "optional": [
    "answer"
   ],
   "params": {
    "answer": "string",
    "column": "string",
    "command": "string",
    "request": "string"
   },
   "result": {
    "task": "string"
   },
   "source": "manual"
  }
```

### Shape of `tasks.status['result']` for `map.smart_ask`

```json
{
  "ok": "bool",
  "status": "proposal|clarify|redirect|out_of_tokens|error",
  "helper": "string",
  "local": "bool",
  "summary": "string",
  "question": "null|string",
  "choices": ["string"],
  "instead": {
    "column": "null|string",
    "hint": "string",
    "request": "null|string"
  },
  "limits": {
    "free_disk": "int",
    "gpu_name": "null|string",
    "ram": "int",
    "vram": "null|int"
  },
  "candidates": [
    {
      "id": "string",
      "title": "string",
      "subtitle": "string",
      "reason": "string",
      "fit": "null|ok|tight|too_large",
      "fit_label": "null|string",
      "size": "null|int",
      "preview": {
        "route": "string",
        "params": "object"
      },
      "connect_after": [
        {
          "command": "string",
          "name": "string",
          "route": "string",
          "params": "object"
        }
      ]
    }
  ]
}
```
- `preview` is the single-step primary action (`installers.preview`, `agents.action_preview`, `connections.preview`, `models.attach_preview`, `mcp.option_preview`, `skills.web_preview`, or `providers.run` for model download/pull).
- `connect_after` (optional, may be empty `[]`) lists eligible agents that can be connected in **Step 4** after a download/install completes, each with its ready-to-call preview route (`connections.preview` or `models.attach_preview`).

---

## 7. Reused Widgets, New Widgets, and New English UI Strings

### Reused as-is
- `TaskReview`, `TaskCardSpec`, `TaskHost` (`task_card.dart`), `TaskProgress` (`provider_task_dialog.dart`).
- `InstallerReview`, `AgentActionReview`, `ConnectionReview`, `ModelRemovalDialog`.
- `_quietTask` / `_awaitTask` (`main.dart`), `corners(context)` (`app_theme.dart`), `modelSize` (`providers_view.dart`).

### New / updated widgets
- `flutter_app/lib/map_smart_card.dart`: `MapSmartCard` (step-by-step card for all 4 columns) and `SmartModelDownloadReview` (clean single-step download confirmation).
- `flutter_app/lib/map_layout.dart` & `flutter_app/lib/map_editor.dart`: column-only group card ordering (`reorderMapCard`) with a 2 px primary-colour drop separator line; `MapSmartCard` pinned at `top: 106`.

### New English UI Strings (for all 8 `translations/*.json` files)
1. `"Ask AI…"`
2. `"Ask AI · {0}"`
3. `"Local, no tokens"`
4. `"Uses plan/tokens"`
5. `"Ask"`
6. `"Find an MCP server or skill…"`
7. `"Set up or connect an agent…"`
8. `"Set up or tune a provider…"`
9. `"Find or connect a model…"`
10. `"{0} is checking {1}…"`
11. `"PC: {0} VRAM · {1} RAM · {2} free"`
12. `"PC: {0} RAM · {1} free"`
13. `"Fits in VRAM"`
14. `"Uses RAM offload"`
15. `"Too large for this PC"`
16. `"Download {0}?"`
17. `"{0} is ready."`
18. `"Connect it to an agent now? (Optional)"`
19. `"Move to {0}"`
20. `"{0} has reached its usage or token limit."`
21. `"Ask {0} instead"`
