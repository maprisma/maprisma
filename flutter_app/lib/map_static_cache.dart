import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/rendering.dart'
    show RenderMouseRegion, RendererBinding, BoxHitTestResult;

/// Flatten the idle map into one texture as well as retaining its display list.
/// A RepaintBoundary alone does not guarantee raster caching of Material layers.
/// Keep real widgets for hit testing, focus and semantics; thaw immediately for
/// input or updates and only capture again after ink/hover animations settle.
class MapStaticCache extends StatefulWidget {
  const MapStaticCache({
    super.key,
    required this.enabled,
    required this.controller,
    required this.child,
    this.contentKey,
  });
  final Object? contentKey;
  final bool enabled;
  final TransformationController controller;
  final Widget child;
  @override
  State<MapStaticCache> createState() => _MapStaticCacheState();
}

class _MapStaticCacheState extends State<MapStaticCache> {
  final _snapshot = SnapshotController();
  final _pointers = <int>{};
  Timer? _settle;
  bool _settled = false;
  RenderMouseRegion? _hoverRegion;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_live);
    _live();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _live();
  }

  void _live() {
    _settled = false;
    _snapshot.allowSnapshotting = false;
    _settle?.cancel();
    if (!widget.enabled || _pointers.isNotEmpty) return;
    _settle = Timer(const Duration(milliseconds: 400), () {
      if (mounted && widget.enabled && _pointers.isEmpty) {
        setState(() => _settled = true);
      }
    });
  }

  void _hover(PointerHoverEvent event) {
    // The nearest hover target changes on box/control enter or exit, not on
    // motion within it. Include controls so their ink/hover feedback stays live.
    final result = BoxHitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    final region = result.path
        .map((e) => e.target)
        .whereType<RenderMouseRegion>()
        .firstOrNull;
    if (region != _hoverRegion) {
      _hoverRegion = region;
      _live();
    }
  }

  @override
  void didUpdateWidget(covariant MapStaticCache old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_live);
      widget.controller.addListener(_live);
    }
    if (old.controller != widget.controller ||
        old.enabled != widget.enabled ||
        widget.contentKey == null ||
        old.contentKey != widget.contentKey) {
      _live();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_live);
    _settle?.cancel();
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Rasterize at the actual on-screen scale, not the unzoomed scene DPR.
      // This avoids wasting a 4x-sized texture on a zoomed-out high-DPI map.
      final media = MediaQuery.of(context);
      // Matrix4's 3D maximum includes an unchanged Z=1 even when XY zooms out.
      final m = widget.controller.value.storage;
      final zoom = math.sqrt(
        math.max(m[0] * m[0] + m[1] * m[1], m[4] * m[4] + m[5] * m[5]),
      );
      final ratio = media.devicePixelRatio * math.min(1.0, zoom);
      final fits =
          constraints.maxWidth * constraints.maxHeight * ratio * ratio <=
          8 * 1024 * 1024;
      // This controller only invalidates RenderSnapshotWidget paint; it never
      // schedules a widget build. LayoutBuilder is where the pixel budget is known.
      _snapshot.allowSnapshotting =
          _settled && widget.enabled && fits && zoom <= 1 && _pointers.isEmpty;
      return MouseRegion(
        onExit: (_) {
          _hoverRegion = null;
          _live();
        },
        child: Listener(
          onPointerDown: (e) {
            _pointers.add(e.pointer);
            _live();
          },
          onPointerUp: (e) {
            _pointers.remove(e.pointer);
            _live();
          },
          onPointerCancel: (e) {
            _pointers.remove(e.pointer);
            _live();
          },
          onPointerMove: (_) => _live(),
          onPointerHover: _hover,
          onPointerSignal: (_) => _live(),
          child: Focus(
            canRequestFocus: false,
            onFocusChange: (_) => _live(),
            onKeyEvent: (_, event) {
              _live();
              return KeyEventResult.ignored;
            },
            child: RepaintBoundary(
              child: MediaQuery(
                data: media.copyWith(devicePixelRatio: ratio),
                child: SnapshotWidget(
                  controller: _snapshot,
                  autoresize: true,
                  mode: SnapshotMode.permissive,
                  // Child layout still sees the real display metrics.
                  child: MediaQuery(data: media, child: widget.child),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
