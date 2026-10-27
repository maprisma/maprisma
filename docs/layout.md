# Page layout

Every page that explains, reviews or sets up something is built the same way, from the layout kit
in `page_parts.py`. A reader always finds the same parts in the same order, and a new page needs no
layout decisions of its own.

## Order, top to bottom

| Part | Helper | What goes in it |
|---|---|---|
| Header | `page_header(title, on_back, tip)` | Back · ⌫ and the page title, over a rule. Outside the scroller: always visible. |
| What happens | `info_card(title, level)` + `card_text` | One or two sentences: what this page does. The first card. |
| Notes | `note_card(box, level, text, title)` | One warning or hint per card, never glued onto another text. |
| Settings | `info_card(_("Settings"))` + `setting_line` rows | What the user can choose. Hidden when there is nothing to choose. |
| Check | `info_card` + `hint_rows(box, hints)` | The result of a check (link_check hints). Its level is the worst hint's (`worst`). |
| Buttons | `action_row(cancel, …, main, start=(status,))` | Right under the cards: Cancel first, a destructive one next, the main action last (right). A status text at the left. |
| Details | `info_card` | Long things last: the file preview, lists. They may scroll; the buttons never move below them. |

Everything between the header and the end is in one scroller (`scrolled`), so a small window
scrolls the page instead of cutting it.

## Levels

A card's level shows as a mark before its heading and a coloured left edge:

| Level | Mark | Use |
|---|---|---|
| `error` | ✕ red | It will not work as it is. |
| `warning` | ! yellow | It may not work, or only after a step of the user's; also "not possible from here". |
| `ok` | ✓ green | Checked and ready. |
| `info` | i accent | What happens, what the user can do. |
| none | — | Plain content (settings, details). |

A card with a level gets a heading that says the state ("Ready", "Before it works", "Not from here
yet"), not a generic one.

## Text

- Card text uses `am-card-text` (13 px), wraps, and can be selected (commands, paths).
- Headings are upper case (`info_card` does it); sentences are not.
- Say what to do next: a hint that only names a problem is not finished.

## Buttons

Make every button with `action_button(label, role=, size=, on_click=, tip=)`:

| | `size="page"` (`am-page-btn`, 13 px) | `size="inline"` (`am-small-btn`, 11 px) |
|---|---|---|
| Use | a page's own actions (`action_row` makes its buttons this size too) | rows, cards, popovers, the progress box |
| `role="primary"` (`am-primary`) | the one action the page is for | the one action a card is for |
| `role="danger"` (`am-danger`) | removing, stopping, cancelling a run | the same, inline |

`am-action-btn` and `am-download-btn` are older names that look like `am-page-btn`. Dialog
responses (Adw.AlertDialog) keep libadwaita's own look. The rules also work in the boxes over the
card (`.am-splash`: the first open's splash, the AI progress box).

## Shared pieces

| Piece | Helper |
|---|---|
| A section heading in a page or card | `section_heading(box, text, muted=True)` (11 px, bold, upper case; `muted=False`: text colour). `settings_heading` and `detail_heading` use it. |
| Explanations | `am-card-text` (13 px); `am-agent-detail` (11 px, dim) only for metadata and short hints |
| Copy | `ui_helpers.copy_button(get_text, tip, label)`: the copy symbol, a tick after copying |
| Text to read, not edit | `ui_helpers.readonly_text(text)`: monospace, the preview look (`am-diff`) |
| Spacing | `ai_core.GAP` (16) between blocks and panes, `GAP_TIGHT` (6) between lines that belong together, `GAP_INLINE` (8) between controls side by side |
| An AI help run | `run_ai_help(title, agent, steps, work, done)`: the progress box (ai_progress) and the protocol entry |

## Pages that follow it

- The connect page (connect_page.py): connecting and removing a line, security changes, skill and
  MCP updates, deleting an MCP server — all fill the same parts.
- The link hints popover uses the same `hint_rows`.

Other pages (Models, Add MCP, Add skills, details) still use their own arrangement; they move to the
kit one by one.
