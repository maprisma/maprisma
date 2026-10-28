# Flutter map editor — implementation response (2026-10-28)

Plan: [plan-flutter-map-editor.md](plan-flutter-map-editor.md).

Implemented locally on `main`; Claude found nothing Medium or higher in the code
review. The requested light-rendering follow-up is implemented and measured:
**134.53% → 56.30% of one core (58.15% lower)** in the controlled scale-1 Xvfb run.
**The real-desktop GPU performance gate is now passed**: Claude measured
9.57% CPU at zoom .53 and 9.07% at zoom 1.25, matching GTK’s 8–11% reference.
Software rendering remains the no-GPU/VM worst case, not a GPU parity result.
This is still the development app, not the production GTK replacement.
Nothing was committed, installed, synced to the live plugin, pushed or published.
Omarchy integration and the new `ubruckhaus.asterism` launcher were not started.

## Service and review flow

- `connections.move_preview` resolves known graph identities against fresh
  installed-agent/runtime facts. A provider move removes and adds in one plan,
  one review, one backup and one Undo. MCP/skill hooks support removal.
- `models.attach_preview` combines selected agents' provider/model edits with
  `connect.chain`, including agents sharing configuration files.
  `models.switch_preview` rechecks configured model users before proposing a
  switch or disconnect. Fixed-provider agents and incompatible models are refused.
  Local loading/unloading is limited to registered runtime operations; active
  consumers or GPU generation prevent unloading.
- Private worker wire v3 carries at most two fixed model API actions. Versions 1
  and 2 still decode. Commands, copied files, retirement and undo commands remain
  refused. Actions and current runtime capabilities are rechecked before writes
  and again before API execution. Partial API failures retain the configuration
  backup and Undo. Reviews explicitly explain that Undo restores files, not API
  load/unload state. Online model choices use existing online-model plans;
  sign-in/sign-out use reviewed registered adapter commands, never UI-supplied argv.
- Failed lines carry bounded hint metadata. Repair uses
  `connections.repair_preview`; repair/removal clear saved hints in the same
  stale-checked file transaction. Removing an unapplied failure changes metadata
  only. Undo restores hints as well as configuration. Dangling provider references
  are checked against the agent's current model before removal.
- `flutter_map_layout` has a separate strict bounded schema for coordinates,
  unique card/node lists, folds, pins and card order. The GTK layout remains
  independent. Layout writes are debounced, do not scan inventory, and are flushed
  on normal window close. Abrupt process termination can lose the last 300 ms of
  layout movement. The existing `map_animations` setting is exposed to Flutter.
- Per-line activity derives from the existing persistent activity tracker and
  registered runtime/GPU metadata. It is an estimate, sampled at map refresh
  cadence; no transcript or configuration contents are exported in the payload.

## Canvas and controls

`map_layout.dart` separates graph semantics from visible positions. Folded cards
still participate in provider/model compatibility. It supplies cubic curves,
line-distance and hook hit tests, node rectangles, target rules, box ordering and
bounded card movement with collision displacement.

The editable AI Map draws connections with a rubber band, compatible target
highlighting, orange movable hooks, hover neighbourhoods, Shift-selection limited
to one agent, and persistent pins. Cards fold, move and reorder; boxes have a
reorder grip and menu alternatives. Existing category expansion remains.

Every connection change uses the existing task review → progress → result/Undo
flow. Cancel sends no Apply request. Main-map selection and transform live outside
the task card; read-only task maps and the System Map retain their existing
renderer. Node buttons open management, start agents in their saved default
folder, show/stop owned consoles, and review external-instance stopping. Local
runtime start/stop buttons use the existing reviewed provider operations.

External stop uses expiring opaque instance handles, with registered-process
membership rechecked in a worker and the existing PID/start-time/pidfd stop guard.
The UI cannot submit an arbitrary PID. External terminal focusing/following is not
added by this slice; Console on the map currently opens owned terminals.

Keyboard alternatives are Actions → Connect / Move connection, activation of the
destination box, Disconnect for the pending hook, and Cancel/Esc. Card arrows,
movement/order menus, Pin and box Move up/down avoid dragging. Hook tooltips
explain compatible destinations and empty-space removal. The normal Open action
remains separate from single-click selection, so selection has no double-click
recognition delay.

Lights use one paced, one-shot ticker, small independently repainted tiles and a
quiescent static-map texture cache. Static curves and node widgets do not rebuild
on light ticks. Requests and phase updates are capped at 30 fps; the actual
software-rendered frame rate is reported below. The ticker stops with no eligible
active edges, Lights off, reduced motion, disabled ticker mode, window focus loss,
or removal of the main map for a task. All / agents / off are persisted.

## Original renderer measurements — retained for comparison

`tools/profile-flutter-editor.py` launches only the Devel binary's explicit
`--map-benchmark-on` / `--map-benchmark-off` fixture, on a private Xvfb display.
The fixture starts no backend, sessions or migration and reads no user settings.
No window was opened on the real desktop and no real pointer/keyboard was driven.
Xvfb was extracted to `/tmp/asterism-headless` for this measurement, not installed.

Each Flutter measurement has a five-second warm-up and a 60-second sample. CPU
includes all threads of the app process, as a percentage of one logical core;
Xvfb is recorded separately. Software OpenGL (`LIBGL_ALWAYS_SOFTWARE=1`) is used.

| Run | Lights off | Lights on | Separate Xvfb CPU with lights |
| --- | ---: | ---: | ---: |
| Initial Devel fixture, default Mesa threads, native default viewport | 0.00% | 716.78% | 37.52% |
| Earlier 1600 × 1400 logical window, 39 boxes / 39 edges, 11 working agents, zoom .53, `LP_NUM_THREADS=1` | 0.00% | 134.60% | 15.63% |

The second run used Devel `preview-lmgl23i8`. The follow-up found that these
earlier runs inherited **`GDK_SCALE=2`**, while the Cairo reference explicitly
rendered at scale 1. Their logical window size must not be read as the physical
rendering size. The controlled scale-1 baseline and after measurements below
replace that comparison. The initial native viewport clipped part of the scene, so its
result is retained as a diagnostic, not the final comparison. Limiting Mesa
threads is a measurement setting, not a change to users' desktop environment.

The existing GTK `tools/profile-map.py --agents 11 --renderer cairo --width 1600
--height 1400 --scale 1 --frames 100`, also on a private X display, measured:
23.2 ms first drawing, 2.51 ms Python per light frame, 4.27 ms renderer work after
subtracting empty-frame readback, or **20.3% of one core at 30 fps**. GTK's recorded
real-desktop reference remains about 1% idle and 8–11% active. An attempted Cairo
run with no display failed in GTK initialization; the reported run used Xvfb.

**Flutter's software-rendered lights are clearly worse.** The GTK number is a
frame-cost estimate, whereas Flutter's is a whole process sample, and Cairo and
software OpenGL have different paths; these results do not establish hardware
GPU performance. They do establish an unresolved software-renderer cost, not a
performance pass. Lights off is the available low-cost mode.

The original proposal (implemented in the follow-up below) was to profile
raster/compositor work, bound the
animated damage to small light tiles rather than the full scene overlay, and
compare pre-rendered light textures with the current circle draws. Keep the static
map cached and cap light frame production to the intended 30 fps. Re-run this
fixture with both software rendering and an accelerated **isolated VM** before
claiming parity. Do not silently change the user's renderer or desktop settings.

Reproduce the corrected measurement with:

```sh
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py \
  --binary .flutter-previews/preview-lmgl23i8/flutter_app/build/linux/x64/release/bundle/asterism \
  --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 2
```

## Claude performance follow-up (2026-10-28)

Nothing was committed, pushed or synced. No command, window, notification or input
test was run against Uwe's real desktop. All native launches used the private
Xvfb display. The visible GPU measurement is left to Claude, with Uwe's permission.

### What changed

1. **Bounded damage:** `map_lights.dart` divides the light layer into 64 × 64 scene
   tiles. Each has its own repaint signal and RepaintBoundary. A frame touches
   only tiles containing old or new marks; old-only tiles repaint once to erase.
   No scene-sized animated canvas is repainted. Marks crossing a tile boundary
   are painted in both clipped tiles; marks behind nodes remain hidden. Very
   large layouts progressively coarsen the grid before allocation exceeds 4,096
   tiles.
2. **Circle/sprite comparison:** both paths share geometry, tile assignment and
   frame pacing. The sprite is one pre-rendered 32 × 32 image, displayed as the
   same 8 × 8 scene mark with a three-unit visible radius. It is shared by all
   tiles and disposed when replaced. **Sprites are now the default**, because
   their final measured CPU was marginally lower. The 0.20 percentage-point
   difference is a near tie, not evidence of a substantial sprite advantage.
   The explicit circle mode remains in the developer benchmark for reproduction.
3. **Static cache:** a RepaintBoundary retains the static map. Flutter's
   SnapshotWidget additionally flattens the idle Material/widget layers into one
   texture after 400 ms of quiescence. It immediately returns to live rendering
   on pointer input, held presses, keyboard/focus activity, transforms, graph or
   layout updates, theme changes and accessibility/display changes. Widget hit
   testing, focus and semantics are retained. The snapshot uses the actual 2D
   on-screen zoom × DPR, keeps the children's real display metrics, and has an
   8-megapixel budget. Above 1:1 zoom or over budget it uses live vector rendering.
   The high-DPI test covers the otherwise oversized 39-box scene at DPR 2 / zoom
   .53. Caching does not replace or freeze task-card state.
4. **Frame production:** the original continuously running ticker requested
   vsyncs even when its phase value was throttled. One one-shot ticker now sleeps
   between paced requests. A timestamp guard caps light updates at 30 fps, with
   no pending light frames/timers when disabled or disposed. Tests count actual
   ticker callbacks as well as phase changes. Delivered FPS on Xvfb is lower;
   it is reported rather than assumed to be 30.
5. **Profiling controls:** `tools/profile-flutter-editor.py` now explicitly sets
   GDK scale and DPI scale, prints the environment, and supports
   `--lights default|circles|sprites` and `--modes both|on|off`. Default uses the
   renderer selected for the app and remains compatible with the original
   benchmark flags. The developer fixture reports build/raster FrameTimings in
   ten-second windows; these diagnostics do not run in the normal application.

### Controlled before/after

Same 39-box / 39-edge fixture, 11 active agents, zoom .53, 1600 × 1400 logical
window and private screen, **GDK_SCALE=1, GDK_DPI_SCALE=1,
LIBGL_ALWAYS_SOFTWARE=1, LP_NUM_THREADS=1**. Every CPU sample has a five-second
warm-up followed by **60 seconds**. Numbers include all app threads; Xvfb is
listed separately. These are whole-process CPU samples, not frame-cost estimates.

| Renderer / state | App CPU, % of one core | Xvfb CPU | Delivered FPS after startup |
| --- | ---: | ---: | --- |
| Unchanged full-overlay baseline (`preview-fzwrdnje`) | **134.53%** | 15.07% | Not instrumented in old bundle |
| Final bounded circle tiles (`preview-rb2e6rey`) | **56.50%** | 10.68% | 19.74 average |
| Final bounded sprites (`preview-rb2e6rey`, retained path) | **56.30%** | 10.65% | 20.16 average |
| Lights off (renderer-independent path) | **0.02%** | 0.00% | No ongoing frames |

The final sprite reduction from the controlled baseline is **58.15%**. The old
134.60% historical sample was at inherited scale 2; it is not silently mixed with
these scale-1 results. Re-running the untouched baseline at explicit scale 1
produced 134.53%, independently confirming the before value used above.

The intermediate version with full-resolution static caching measured 63.10%
with circles and 63.95% with sprites at scale 1. Caching at the actual zoomed
pixel resolution brought those to 56.50% and 56.30%. Tiling alone, before the
proper static cache and scale controls, still measured 133.93% at inherited scale
2 and about 7 fps; it did not solve the problem by itself.

The first ten-second FrameTiming window includes startup and is excluded from
steady frame-time summaries. In the subsequent windows:

| Final path | Mean Dart build time | Mean raster wall time | Raster p95 across windows |
| --- | ---: | ---: | ---: |
| Circle tiles | 0.302 ms | 9.813 ms | 10.094–10.432 ms |
| Sprites | 0.308 ms | 9.831 ms | 10.164–10.306 ms |

Xvfb reports a display refresh rate of zero; pacing uses the 60 Hz fallback. The
actual delivered rate varies around 19–21 fps despite the 30 fps ceiling. Timing
values are wall durations, not a direct split of process CPU. They show low Dart
build cost; native raster/presentation/compositing remains a candidate for the
remaining cost, not a proved CPU attribution. Release Devel FrameTimings were
sufficient for this comparison; no separate profile build was needed.

**Historical Xvfb checkpoint (superseded by the GPU result below):** the requested
optimization and comparison were complete, but this is
still **not a software-rendering parity pass**: 56.30% remains above the GTK Cairo
estimate of 20.3%, and GTK's estimate assumes 30 fps. These different rendering
paths and the lower delivered Flutter FPS must stay visible in the review.
These software runs made no accelerated-GPU claim. At that checkpoint Claude’s
authorized GPU measurement was the next decision input; the subsequent result
below passes the gate. Codex did not run a real-desktop measurement.

Reproduce final candidates (run sequentially):

```sh
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py \
  --binary .flutter-previews/preview-rb2e6rey/flutter_app/build/linux/x64/release/bundle/asterism \
  --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --lights circles
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py \
  --binary .flutter-previews/preview-rb2e6rey/flutter_app/build/linux/x64/release/bundle/asterism \
  --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --lights sprites
```

For the old baseline use `preview-fzwrdnje` with `--lights default`; its older
binary accepts the original `--map-benchmark-on` flag. For future builds, omitting
`--lights` tests the selected production path. The final default-only change and
numeric viewport diagnostics do not change the measured explicit sprite path. A
separate 10-second default-path smoke run of `preview-z8ryjc4j` measured 55.30%
and confirmed physical viewport `[1600, 1400]`, DPR 1. This short smoke sample is
not substituted for the 60-second comparison above.

Validation for this follow-up: **75 Flutter tests pass**, format/analyzer clean,
Python type checking **0 errors, 0 warnings**. Seven new tests cover bounded dirty
tiles and erasure, huge layouts and agent-only filtering, both drawing paths,
static-cache repaint isolation and input/update/zoom invalidation, high-DPI pixel
budgets, and counted 30 fps ticker requests with idle cancellation. Service code
and source translations were not changed by this performance follow-up.

## Checks and documentation

- Python: **1,414 tests pass**; type checking reports **0 errors, 0 warnings**.
  New tests cover merged edits/Undo, hostile inputs, stale model users and files,
  failure repair/removal metadata, API partial failure, wire compatibility,
  registered sign-out and opaque external-instance stopping.
- Flutter: formatting and analysis are clean; **75 tests pass** after the performance follow-up.
  Tests include pure hit/target/layout cases, drawing, hook removal/moves,
  keyboard connection, card movement, reorder, folds/pins, selection/model picks,
  light lifecycle, and app-level review/Cancel/Apply/Undo flows.
- All new UI keys are present in all eight Flutter languages. Existing source
  translation keys, values and order are preserved; additions are appended.
- A new manual chapter is translated into all eight languages. All eight PDFs
  rebuilt; the English editor page was rendered and checked for clipping.
  The pre-existing `about` and `running-agents` translation fingerprint warnings
  remain; only the new editor section was stamped. The existing two-page contents
  layout and chapter 1 on physical page 5 are unchanged.
- Latest isolated Devel build:
  `.flutter-previews/preview-jdyiolim/flutter_app/build/linux/x64/release/bundle/asterism`.
  Codex launched benchmark modes only on private displays; Claude’s separately
  authorized real-desktop measurement is recorded below.

The editor plan and this response remain in `docs/` for review. Feature parity,
broader accelerated/edge-VM validation, remaining migration screens and production rollout
are still outstanding. No Omarchy edge code was run on Uwe's desktop.


### Follow-up on live scans, hover and zoom

[Claude’s map-lights review responses](review-claude-2026-10-28-map-lights-responses.md)
record the subsequent equal-snapshot gate, metadata-only layout/tile reuse,
hover-region invalidation and six-second delivery/hover/zoom measurements.
Current checks are 82 Flutter tests and 1,414 Python tests. The slice remains
uncommitted. Claude’s subsequently authorized GPU measurement passes the
performance gate; details follow.


## Real-desktop GPU gate — passed (Claude, 2026-10-28)

Source: [Claude’s appended GPU measurement](review-claude-2026-10-28-map-lights.md#real-desktop-gpu-measurement-claude-2026-10-28-with-uwes-permission).
This was run **by Claude with Uwe’s permission**, not by Codex. No additional
real-desktop run was made for this documentation update.

Devel `preview-jdyiolim`, hardware GL, benchmark fixture with no backend and
private XDG config/cache, visible empty workspace 9. Monitor: HDMI-A-1,
3840 × 2160, scale 2, 60 Hz. Actual physical window: **3792 × 1958, DPR 2**
(about 3.4 times the pixels of the scale-1 Xvfb fixture). No input was sent;
Claude returned to workspace 1 afterwards. Five-second warm-up, then the samples
below; app CPU includes all threads, with one logical core = 100%.

| Case | Sample | App CPU | Hyprland CPU | GPU busy | Delivered FPS | Raster mean |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Lights off | 20 s | **0.05%** | 1.70% | 3.9% | idle | — |
| Lights on, zoom .53, mixed updates every 6 s | 60 s | **9.57%** | 2.06% | 7.8% | 19–21 | 0.56–0.74 ms |
| Lights on, zoom 1.25, mixed updates every 6 s, live-vector path | 60 s | **9.07%** | 1.93% | 8.0% | 19–21 | 0.55–0.73 ms |

**Decision: the map-editor GPU performance gate is passed.** The active CPU cost
matches GTK’s real-desktop 8–11% reference, and the large software zoom penalty
was not present on this GPU. The earlier Xvfb measurements remain documented as
the no-GPU/VM worst case. This supersedes the earlier “GPU measurement pending”
checkpoint, without claiming software-rendering parity or completing the wider
Flutter migration.

### Optional pacing Low — initially deferred (superseded below)

Claude identified that the wake-up plus the strict `since + 1 >= period` guard
can miss the intended paced vsync on a real 60 Hz display, producing 50 ms frames
and 19–21 fps. The suggested adjustment is to accept
`since >= period - vsync / 2`, with a regression test for the early vsync.

The clock is unchanged in this update: the GPU pass above applies to the measured
19–21 fps implementation. Raising delivery to 30 fps would change the workload;
its CPU cost must be measured again rather than inferred from these results.
This Low is optional and does not reopen the accepted gate for the current
implementation. No commit, push or plugin sync was made.

### User-selected cadence settings — supersedes the optional pacing deferral

Uwe chose **20 fps by default**, with **30/60 fps** available in Settings, and
explicitly waived further measurement. This is implemented with System/Light/Dark
preview choices in the [appearance response](plan-flutter-appearance-responses.md).
Synthetic-clock tests cover the selected rates and early vsync tolerance. The GPU
numbers above remain measurements of the earlier 19–21 fps version; they are not
new claims about higher frame rates. No additional performance run was made.


The GPU sample used Claude's scratchpad `gpu-test.py`; Claude reported that no
process remained after returning to workspace 1. The optional pacing correction
is now implemented with `since >= period - vsync / 2` and synthetic early-vsync
tests for 20/30/60 fps. The estimated roughly 14% CPU at 30 fps is an
extrapolation, not a measured result. Uwe waived further measurement and retains
the decision whether to commit; nothing has been committed or pushed.
