# Review: map lights performance follow-up (Claude, 2026-10-28)

Scope: `flutter_app/lib/map_lights.dart`, `map_static_cache.dart`, their use in `map_editor.dart`, the
performance section of `plan-flutter-map-editor-responses.md`. Rechecked: `tools/flutter-dev check`
(75 tests pass, format/analyzer clean), Python 1,414 tests OK.

Nothing Medium on correctness or security. The tiles, the one-shot 30 fps clock and the cache are sound:
the clock stops cleanly, the tile grid is bounded (4,096), curves stay inside their start/end box (control
points at the middle x), so no marks are lost; boxes have no animated children that a snapshot would freeze.
The measurement is honest (scale-1 baseline re-run, Xvfb separate, no parity claim).

## Findings

1. **Medium (performance, real use not measured): every map scan thaws the cache and rebuilds the lights.**
   `main.dart:_refreshLive` sets a new `_graph` on every scan (default `map_scan_interval` 6 s, every 2 s
   while `pending`), even when nothing changed. `MapEditor.didUpdateWidget` then drops `_layout`
   (`map_editor.dart:74`), `MapLightLayer` disposes and rebuilds all tiles, and `MapStaticCache` goes live
   for 400 ms and then rasterizes the whole scene again. The benchmark fixture has no backend, so the
   56.30 % never includes this. Fix: skip the `setState` when the new snapshot is deep-equal to the old one
   (or compare a signature from the service), keep the layout when only `activity` changes, and add a
   benchmark variant that delivers an unchanged and a changed graph every 6 s.
2. **Low: hovering the map keeps the cache live.** `onPointerHover` calls `_live()`, so with the pointer
   resting over the map (the normal case while watching agents) the cost is the live vector path, not the
   cached one. Measure it once (benchmark with a synthetic hover every 100 ms); if it is close to the old
   number, thaw only on hover changes that alter `_hover` (box enter/exit), not on every move.
3. **Low: zoom above 1 always renders live** (`zoom <= 1` in `map_static_cache.dart`). Fine as a pixel
   budget; record the cost at zoom 1.0–1.5 in the responses, since users zoom in to read boxes.
4. **Low: `allowSnapshotting` is written inside `build`** (`map_static_cache.dart`, LayoutBuilder). It works
   (only marks paint), but a comment or moving it into `_live`/the timer callback keeps build side-effect free.

## Go/no-go

Lights on in software: 56 % vs GTK ~20 % (estimate at 30 fps, Flutter delivers ~20 fps), so per frame Flutter
is still about 4× GTK there. Next input stays the short GPU measurement on the real desktop (empty workspace,
about 70 s), only with Uwe's permission, after finding 1 is fixed so the number reflects real use.
Until then keep `animate` default as is but do not commit the slice as "performance done".

## Real-desktop GPU measurement (Claude, 2026-10-28, with Uwe's permission)

Devel `preview-jdyiolim`, benchmark fixture (no backend, private XDG config/cache), on visible empty
workspace 9 of Uwe's desktop (HDMI-A-1 3840×2160, scale 2, 60 Hz; physical window 3792×1958, DPR 2, i.e.
about 3.4× the pixels of the Xvfb runs). Hardware GL, no input sent, back to workspace 1 afterwards.
Script: scratchpad `gpu-test.py` (5 s warm-up, then the sample; CPU over all app threads, one core = 100 %).

| Case | App CPU | Hyprland CPU | GPU busy (card1) | Delivered FPS | Raster mean |
|---|---:|---:|---:|---:|---:|
| Lights off, 20 s | 0.05 % | 1.70 % | 3.9 % | idle | — |
| Lights on, zoom .53, mixed updates every 6 s, 60 s | **9.57 %** | 2.06 % | 7.8 % | 19–21 | 0.56–0.74 ms |
| Lights on, zoom 1.25 (live vector), mixed updates, 60 s | **9.07 %** | 1.93 % | 8.0 % | 19–21 | 0.55–0.73 ms |

**Result: parity with GTK on the real desktop** (GTK real-desktop reference: about 1 % idle, 8–11 % with
lights). The zoom penalty seen in software rendering does not exist on the GPU. The software numbers stay as
the worst case (no GPU / VM).

One new Low: delivered light rate is 19–21 fps, not the intended 30, on a real 60 Hz display too. The
`MapLightClock` wake-up (`interval - min(4000, vsync/4)`) plus the `since + 1 >= period` guard misses every
other paced vsync, so frames land at 50 ms. Lights look a bit slower than GTK; CPU at 30 fps would be about
1.5× these numbers (about 14 %, slightly above GTK's 8–11 %). Fix optional: accept `since >= period - vsync/2`.
