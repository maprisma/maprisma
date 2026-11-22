# Review: 093 Step 6 (screenshots, manual, retained-view tooltips)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-093-checks/`.

## Checks
- The tooltip bug is seen in the real app (Devel preview on Hyprland): the tooltip stayed over the
  Projects board after the badge click. Closing all tooltips before the tab switch (first attempt)
  did not help and was removed. `TooltipVisibility(visible)` fixed it in the real app but rebuilds
  the tooltip's child when it flips (focus nodes lost: Codex r1), so it was replaced.
- `tests.test_manual`, `tests.test_manual_translations`, `tests.test_i18n` pass; only the sections
  changed here are stamped (ai-project-center, project-center-workflow, keyboard-flutter, reports).

## Round 1 → fixes
- RetainedTaskView keeps its subtree as it is and closes all tooltips in the frame after it became
  hidden (post-frame `Tooltip.dismissAllToolTips`). The test now checks that the state under a
  tooltip survives hide/show (fails with the TooltipVisibility version: 3 states instead of 1),
  that the tooltip is gone with `skipOffstage: false`, and that tooltips work again when shown.
  Widget tests still cannot reproduce the stuck tooltip itself; the real-app check of this version
  is pending (Uwe was using the screen).
- Manual: card issue line described exactly (the project's own problems; for an approved project
  that cannot start also what stops the run; agents with a problem are marked) in 8 languages;
  nl Setup tab name; pt Retrocesso; fr/pt Reports sentence in the section's informal address;
  keyboard paragraph lead-in "Projects and AI Map"; Enter as a key in the Phases sentence.

## Round 2 → fixes
- Real-app check: the post-frame dismiss alone still left the tooltip (its fade-out needs the
  hidden view's tickers). Now the view keeps its tickers 400 ms after hiding, timed by its own
  `AnimationController` (no pending `Timer` in widget tests), then mutes them. Verified in the real
  app: no tooltip over the board after the badge click.
- Tests: the tooltip test now lets the tooltip fade in fully before hiding (fails without the
  settling period), and a focus test keeps a focused tooltip button's node attached and focusable
  after hide/show (fails with the TooltipVisibility version). Main-tab and link tests (60) pass.
- Task doc updated (no TooltipVisibility); Uwe's two requests added (provider box entry "Setup";
  the window overview for the Flutter window).

## Round 3 → fixes
Codex: pins 2 and 6; agy: figure 1 in the introduction uses the same image and still had the GTK
caption/alt (now the Flutter window, 8 languages; introduction stamped), pins 1/2, French and
Portuguese link texts to the group-cards chapter (fr "extensions", pt "complementos"). Pins checked
by drawing them on the image: 1 under the Projects tab, 2 beside the header symbols, 6 on the line.

## Round 4
Codex CLEAN, agy CLEAN.
