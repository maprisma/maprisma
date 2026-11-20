# 079 Compact Settings

Author: Codex · Reviewers: Claude and Antigravity · Branch: task/079-compact-settings

## Goal

Keep every Settings section and its controls reachable in compact windows and
with large text. Implement the compact Settings boundary from the experience
plan, independently of setup and interrupted-job recovery.

Base: `2dd54ff` on `main`, including tasks 077 and 078. The existing experience
plan remains in the Codex checkout as an untracked planning document.

## Routes

None. Keep the existing Settings operations and global search.

## UI

Use a compact section selector when the available width and text size cannot
support a sidebar and content. Make wide-layout section navigation scroll at
short heights. Preserve the selected section, search query and keyboard focus
when resizing. Explicit section changes keep their existing search-clearing
behavior. Reuse translated labels and document responsive navigation in all
eight manuals.

## Acceptance

- Every section is reachable at 540 × 400 and 960 × 640 without overflow.
- German and Polish text and 150%/200% text sizes remain usable, with scrolling.
- Search continues to find groups across sections and identify their section.
- Resizing preserves search, selected section and visible keyboard focus.
- Keyboard users can select sections and reach their settings; short wide
  windows scroll focused navigation items into view.
- Light and dark fixture captures are inspected; no live settings are changed.
- Run only the affected Settings tests, changed-file analysis and documentation
  checks. Uwe's 2026-11-20 instruction reserves full suites for before a push;
  it supersedes the earlier broad branch-check/release-build rule. Independent
  reviews by Claude and Antigravity must be addressed before completion.

## Implementation and verification (2026-11-20)

- Responsive section selector below an effective width of 840 pixels, accounting
  for text scaling. Its selected label stays compact with a full-label tooltip;
  popup choices wrap. The wide sidebar scrolls and keeps focused items visible
  after height changes. Search and content retain their element positions on
  resize, preserving their state and focus.
- Dropdown values in Settings and Dictation can grow vertically for translated
  large text. Dictation's status and test action fit the available width.
  Activity retention keeps its existing controlled/persisted-value behavior.
- **19 Settings layout tests pass**, including 12 German/Polish size/scale
  combinations, global search, keyboard visibility, pointer/keyboard open-menu
  resizing, menu cancellation, and an unsaved retention update.
- **13 related existing tests pass** across appearance, LLM Settings and map
  Settings. Changed-file analysis and formatting pass for the two source files
  and the layout test. No full suites were run.
- **Six fixture renders pass**, with light/dark captures at 540 × 400 (200%
  German/Polish) and 960 × 640 (English), using Noto Sans. Artifacts are local
  and excluded from commits in `.flutter-previews/task-079/`.
- The usual Flutter runner cannot bind its local socket in this sandbox. The
  scoped tests instead use Flutter's headless engine, the normal test assets,
  Ahem test fonts, and `test_core`'s direct runner with the VM service disabled.
  A temporary harness and a writable copy of the installed SDK remain outside
  commits; production tooling and the installed SDK are unchanged.
- **Two existing Dictation integration tests fail identically on the base and
  changed source.** This sandbox exposes `/` and `/home` as owned by `nobody`;
  the core's private-write ancestor check refuses them. The Settings test then
  cannot select its Whisper fixture, and the Ask AI test directly reports
  `Unsafe private-write ancestor`. No protection was weakened. These tests need
  an ordinary host environment.
- The responsive navigation paragraph is translated in all eight manuals.
  The Settings-section fingerprints are updated. The manual checker still
  reports seven other stale sections per translated manual, also present on
  the unchanged base; those sections are outside this task.
- A separate Codex source review is CLEAN after fixes. Requested external
  reviews remain **blocked**: Antigravity cannot start its socket server
  (`operation not permitted`), and Claude cannot reach its API (`EAI_AGAIN`).
  Neither is claimed as a completed review.

Evidence: `/tmp/maprisma-079-final-layout.log`,
`/tmp/maprisma-079-related.log`, `/tmp/maprisma-079-analysis.log`,
`/tmp/maprisma-079-dictation-baseline.log` and
`/tmp/maprisma-079-manual-baseline.log`. The original author-branch Dictation
failures are in `/tmp/maprisma-079-final-focused.log`.

The task awaits the two host-environment integration checks and external
reviews. No push, release or live-settings operation is part of this task.
