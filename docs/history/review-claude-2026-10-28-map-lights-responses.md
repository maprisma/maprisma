# Map lights review responses — Codex (2026-10-28)

Review: [review-claude-2026-10-28-map-lights.md](review-claude-2026-10-28-map-lights.md).

Finding 1 is fixed. Finding 2 was measured and its hover invalidation was narrowed.
Finding 3 is measured below; the existing live-vector policy above zoom 1 remains.
Finding 4 is documented in the code. Everything remains uncommitted on `main`.
Nothing was pushed or synced, and no real-desktop run or notification was made.
The `animate` default remains unchanged. This is not a performance-parity sign-off.

## 1. Snapshot, layout and light reuse — fixed

`map_snapshot.dart` compares the bounded JSON snapshot deeply, with map key order
ignored and list order preserved. `_refreshLive` retains the previous snapshot
and skips `setState` when it is equal. A failed-state recovery still updates the
UI, and a `pending` transition is not discarded. Repeated pending polls with the
same data also leave the map widget untouched.

`MapLayout.updateGraph` separates geometry from metadata. The ordered node
identities/columns/kinds/groups and edge endpoints/kinds determine geometry.
When those match, the same layout, node rectangles, curve objects and cached
bezier paths are retained; their metadata is refreshed. A changed topology or
saved layout still recomputes geometry.

The light tile grid is allocated for all visible curve geometry, within the
existing 4,096-tile bound, so changing which edges flow does not dispose/rebuild
the grid. The active subset is read from current metadata. Existing tiles and
the sprite are retained, and old marks are erased when an edge stops flowing.

The static image has an explicit content revision. Light activity and invisible
activity metadata do not thaw it. Labels, node status, failures, visible subagent
badges, group counts, language/theme/display changes, local selection/hover,
and external control state still invalidate it. The main app supplies external
snapshot/busy/terminal/language state so new console/stop controls cannot be
hidden behind an obsolete image.

The six-second benchmark now uses the **same retention helper** as live delivery:

- `--updates unchanged`: a fresh JSON copy every six seconds, rejected as equal.
- `--updates changed`: a visible node detail changes every six seconds. It is
  accepted, updates the box and thaws the static image, but retains geometry and
  tiles.
- `--updates mixed`: alternate equal and visibly changed deliveries.
- `--updates activity`: toggle one agent's three light edges and working flag
  every six seconds, retaining static pixels, geometry and tiles.

Unit/widget tests verify equal-snapshot identity, pending transitions, retained
curve paths/tiles/sprite/cache on activity updates, visible metadata and badge
invalidation, and topology replacement. App-level tests verify that normal live
scans and pending polls really occur without replacing equal map widgets.

## 2. Continuous hover — measured and fixed

The benchmark injects a Dart `PointerHoverEvent` every 100 ms, alternating by one
scene unit within the same agent box. It never moves the OS pointer or sends
input to another window. Tooltips are disabled only in the developer fixture so
the measurement isolates cache invalidation rather than tooltip presentation.

The original per-move invalidation measured **85.95% of one core**. The fix keeps
the image cached during motion within the same hover target. A change of the
nearest box/control hover region, or exit from the map, thaws it. Controls are
included as well as boxes so button ink/hover feedback remains live. Presses,
drags, keyboard input and transforms continue to thaw immediately.

A widget test sends continuous motion over one button and checks that the cache
stays enabled, then enters another button and checks that it thaws. A stationary
pointer does not itself produce periodic hover events; the costly case measured
here is continuous motion.

## 3. Zoom 1.0–1.5 — measured, policy retained

The benchmark accepts a bounded `--zoom` option and retains the same 39-box /
39-edge fixture. Zoom 1.0 uses the static texture cache; 1.25 and 1.5 use live
vector rendering under the existing `zoom <= 1` policy. The viewport remains
1600 × 1400, so zooming in clips more of the same scene, as in normal use. The
reported rates are delivered frame rates, not an assumption of 30 fps.

## 4. Snapshot-controller write during build — documented

The LayoutBuilder now explains that assigning `allowSnapshotting` only
invalidates `RenderSnapshotWidget` paint; it does not schedule a widget build.
The assignment stays beside the size/zoom/DPR pixel-budget calculation. There is
no `setState` from this build callback.

## Measurement method and results

All native runs use private Xvfb, Devel identity, `GDK_BACKEND=x11`,
`GDK_SCALE=1`, `GDK_DPI_SCALE=1`, `LIBGL_ALWAYS_SOFTWARE=1` and
`LP_NUM_THREADS=1`, five seconds of warm-up and **60 seconds of measurement**.
The fixture starts no backend, migration or agent. App CPU includes all its
threads and is expressed as a percentage of one logical core; Xvfb is separate.
The eight final scenarios run sequentially on the same binary. Build/raster
FrameTimings exclude the first startup window in steady summaries.

Before-hover binary: `preview-jjrbss1s` (finding 1 fixed, old per-move thaw).
Final binary: `preview-jdyiolim` (snapshot reuse and narrowed hover invalidation).

| Case | App CPU | Xvfb CPU | Delivered FPS | Mean raster wall time |
| --- | ---: | ---: | ---: | ---: |
| 100 ms hover, original per-move thaw | 85.95% | 9.45% | 16.84 | 31.81 ms |
| Equal snapshots every 6 s, zoom .53 | 56.02% | 10.80% | 20.16 | 9.42 ms |
| Visible text changes every 6 s, zoom .53 | 59.37% | 10.35% | 19.83 | 11.26 ms |
| Alternating equal/changed snapshots every 6 s | 56.83% | 10.27% | 20.02 | 10.58 ms |
| Light activity changes every 6 s, zoom .53 | 56.22% | 10.60% | 20.16 | 9.48 ms |
| 100 ms hover, narrowed thaw | 56.42% | 10.75% | 20.16 | 9.92 ms |
| Zoom 1.0, static cache enabled | 71.35% | 10.62% | 20.16 | 17.03 ms |
| Zoom 1.25, live-vector path | 116.22% | 7.08% | 13.20 | 76.11 ms |
| Zoom 1.5, live-vector path | 115.98% | 7.17% | 13.38 | 74.80 ms |

The last ten-second report (near 60 seconds) recorded **9 equal deliveries /
0 accepted**, **9 visible changes / 9 accepted**, and **9 activity deliveries /
9 accepted**. The mixed case reported **9 deliveries / 4 accepted**. A delivery near the sample boundary can occur after that report;
these counters describe the report rather than claiming an exact total for the
CPU interval. Hover reports recorded about 600 synthetic events. Dart build
time stayed around 0.31–0.39 ms per frame in steady windows.

Equal delivery stays near the old 56.30% static baseline. Genuine visible
changes have a measurable cost (59.37%); alternating equal/changed deliveries
cost 56.83%, while activity-only changes (56.22%)
retain the cache and geometry. Narrowed hover invalidation reduces the measured
hover CPU from 85.95% to 56.42%, **34.36% lower**. The zoom penalty is substantial above 1:1;
no attempt was made to hide it or silently change the zoom/cache policy.


The historical static-fixture result was 56.30%. It did not include snapshot
delivery or continuous hover; it is retained as context rather than substituted
for these new measurements. The GTK reference remains a Cairo frame-cost
estimate of about 20.3% at 30 fps, not a whole-process native-window sample.

## Reproduce

From the repository root, run these sequentially, with
`BINARY=.flutter-previews/preview-jdyiolim/flutter_app/build/linux/x64/release/bundle/asterism`:

```sh
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --updates unchanged
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --updates changed
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --updates mixed
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --updates activity
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --hover
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --zoom 1.0
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --zoom 1.25
LP_NUM_THREADS=1 python3 tools/profile-flutter-editor.py --binary "$BINARY" --xvfb /tmp/asterism-headless/usr/bin/Xvfb --seconds 60 --scale 1 --modes on --zoom 1.5
```

For a future GPU pass, use `--updates mixed` (or the separate unchanged/changed
cases) so legitimate periodic updates are included. Such a pass still requires
Uwe’s permission and was not run here.

For the before-hover control use `preview-jjrbss1s` with `--hover`. The fixture
options are strictly parsed; unknown/duplicate flags, invalid update modes and
out-of-range/nonfinite zooms are refused before any backend can start. The
profiler defaults remain compatible with older static-fixture binaries.

## Validation and remaining gate

- Flutter: **82 tests pass**, formatting/analyzer clean.
- Python: **1,414 tests pass**, run against a separate private Xvfb display with
  Wayland unset; type checking reports **0 errors, 0 warnings**.
- Native isolated Devel build succeeds. Source translation values/order are
  preserved. No new product text or manual behaviour was introduced by this
  rendering/data-reuse correction.
- Finding 1 no longer prevents a meaningful real-use measurement. Software
  rendering parity has not been established. Claude's GPU measurement remains
  subject to Uwe's permission; this response does not authorize it.
- No commit, push, plugin sync or real-desktop run.


## Subsequent GPU checkpoint — passed (Claude, with Uwe’s OK)

Claude’s [appended real-desktop measurement](review-claude-2026-10-28-map-lights.md#real-desktop-gpu-measurement-claude-2026-10-28-with-uwes-permission)
supersedes the pending-GPU gate above: 0.05% idle, 9.57% active at zoom .53 and
9.07% active at zoom 1.25, at 3792 × 1958 physical pixels / DPR 2. The active
figures match GTK’s 8–11% real-desktop reference; the software cases above remain
the no-GPU worst case. The GPU performance gate is passed for the measured
19–21 fps clock. The subsequent user-selected frame-rate settings and pacing
fix are recorded below. Codex made no additional desktop run, commit, push or sync. The full table is in
[the map-editor implementation response](plan-flutter-map-editor-responses.md#real-desktop-gpu-gate--passed-claude-2026-10-28).


### GPU sample details and optional pacing Low — addressed

Claude used hardware GL with Devel `preview-jdyiolim`, a backend-free fixture
and temporary XDG config/cache, on visible empty workspace 9. HDMI-A-1 was
3840×2160, scale 2, 60 Hz; the window was 3792×1958 physical pixels, DPR 2
(about 3.4 times the Xvfb pixel count). Each sample followed a five-second
warm-up. App CPU includes all threads; 100% is one core.

| Case | Sample | App CPU | Hyprland CPU | GPU busy | Delivered FPS | Raster mean |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Lights off | 20 s | 0.05% | 1.70% | 3.9% | idle | — |
| Lights on, zoom .53, mixed updates every 6 s | 60 s | 9.57% | 2.06% | 7.8% | 19–21 | 0.56–0.74 ms |
| Lights on, zoom 1.25, live vector, mixed updates every 6 s | 60 s | 9.07% | 1.93% | 8.0% | 19–21 | 0.55–0.73 ms |

Claude sent no input, returned to workspace 1 and left no process running.
The GPU gate is passed against GTK's real-desktop 8–11% reference. The measured
software zoom penalty was absent on this GPU; software measurements remain the
no-GPU/VM worst case.

Uwe subsequently chose **20 fps by default, with 30 and 60 selectable in
Settings**, and waived further measurement. That implementation already accepts
`since >= period - vsync / 2`. Synthetic-clock tests exercise slightly early
60 Hz ticks at all three selected rates, rate changes and disabling the clock.
The earlier pacing deferral is superseded; the default remains 20, rather than
forcing 30. See the [appearance response](plan-flutter-appearance-responses.md)
for the implementation and completed checks (89 Flutter tests, 1,415 Python
tests, clean analyzer/typecheck and an isolated development build).

Claude's roughly 14% CPU at 30 fps is an extrapolation, not a measurement. The
accepted figures above describe the earlier 19–21 fps build; no new performance
claim is made for 30/60. No additional measurements, desktop runs, commits,
pushes or plugin syncs were performed. Uwe decides whether to commit.
