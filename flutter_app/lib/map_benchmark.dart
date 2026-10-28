import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'map_editor.dart';
import 'map_lights.dart';
import 'map_snapshot.dart';

/// Strict developer-only options. Invalid fixture flags never start the app service.
class MapBenchmarkOptions {
  const MapBenchmarkOptions({
    required this.lights,
    this.style = defaultMapLightStyle,
    this.updates = 'none',
    this.hover = false,
    this.zoom = .53,
  });
  final bool lights, hover;
  final MapLightStyle style;
  final String updates;
  final double zoom;
  factory MapBenchmarkOptions.parse(List<String> args) {
    const modes = {
      '--map-benchmark-on',
      '--map-benchmark-off',
      '--map-benchmark-on-circles',
      '--map-benchmark-on-sprites',
    };
    if (args.isEmpty || !modes.contains(args.first)) {
      throw ArgumentError('Invalid benchmark mode');
    }
    var updates = 'none', hover = false, zoom = .53;
    final seen = <String>{};
    for (final arg in args.skip(1)) {
      final key = arg.split('=').first;
      if (!seen.add(key)) throw ArgumentError('Duplicate benchmark option');
      if (arg.startsWith('--map-benchmark-updates=')) {
        updates = arg.substring('--map-benchmark-updates='.length);
        if (!{
          'none',
          'unchanged',
          'changed',
          'mixed',
          'activity',
        }.contains(updates)) {
          throw ArgumentError('Invalid update fixture');
        }
      } else if (arg == '--map-benchmark-hover') {
        hover = true;
      } else if (arg.startsWith('--map-benchmark-zoom=')) {
        zoom = double.parse(arg.substring('--map-benchmark-zoom='.length));
        if (!zoom.isFinite || zoom < .3 || zoom > 2) {
          throw ArgumentError('Invalid benchmark zoom');
        }
      } else {
        throw ArgumentError('Unknown benchmark option');
      }
    }
    return MapBenchmarkOptions(
      lights: args.first != '--map-benchmark-off',
      style: args.first.endsWith('-sprites')
          ? MapLightStyle.sprites
          : args.first.endsWith('-circles')
          ? MapLightStyle.circles
          : defaultMapLightStyle,
      updates: updates,
      hover: hover,
      zoom: zoom,
    );
  }
}

/// Explicit developer fixture: no backend, migration, sessions or user settings.
class MapBenchmark extends StatefulWidget {
  const MapBenchmark({super.key, required this.options});
  final MapBenchmarkOptions options;
  @override
  State<MapBenchmark> createState() => _MapBenchmarkState();
}

class _MapBenchmarkState extends State<MapBenchmark> {
  late final TransformationController _controller;
  late final Timer _report;
  Timer? _deliver, _hover;
  final _wall = Stopwatch();
  final _build = <int>[], _raster = <int>[];
  Map<String, dynamic> _graph = _fixtureGraph();
  int _deliveries = 0, _accepted = 0, _hovers = 0;
  bool _pointerAdded = false;
  static const _device = 9271;
  @override
  void initState() {
    super.initState();
    _controller = TransformationController(
      Matrix4.diagonal3Values(widget.options.zoom, widget.options.zoom, 1),
    );
    _wall.start();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    if (widget.options.updates != 'none') {
      _deliver = Timer.periodic(const Duration(seconds: 6), (_) => _snapshot());
    }
    if (widget.options.hover) {
      _hover = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _pointer(),
      );
    }
    _report = Timer.periodic(const Duration(seconds: 10), (_) {
      final seconds = _wall.elapsedMicroseconds / 1000000;
      if (_raster.isNotEmpty) {
        final sorted = [..._raster]..sort();
        final metrics = jsonEncode({
          'physical_size': [
            View.of(context).physicalSize.width,
            View.of(context).physicalSize.height,
          ],
          'dpr': View.of(context).devicePixelRatio,
          'refresh_hz': View.of(context).display.refreshRate,
          'zoom': widget.options.zoom,
          'updates': widget.options.updates,
          'hover': widget.options.hover,
          'deliveries': _deliveries,
          'accepted': _accepted,
          'hover_events': _hovers,
          'seconds': seconds,
          'frames': _raster.length,
          'fps': _raster.length / seconds,
          'build_ms': _build.reduce((a, b) => a + b) / _build.length / 1000,
          'raster_ms': _raster.reduce((a, b) => a + b) / _raster.length / 1000,
          'raster_p95_ms': sorted[((sorted.length - 1) * .95).floor()] / 1000,
        });
        debugPrint('MAP-BENCHMARK $metrics', wrapWidth: 2048);
      }
      _raster.clear();
      _build.clear();
      _wall.reset();
    });
  }

  void _snapshot() {
    _deliveries++;
    final next = jsonDecode(jsonEncode(_graph)) as Map<String, dynamic>;
    final mode = widget.options.updates;
    if (mode == 'changed' || (mode == 'mixed' && _deliveries.isEven)) {
      (next['nodes'] as List).first['detail'] = 'Benchmark update $_deliveries';
    } else if (mode == 'activity') {
      for (final edge in next['edges'] as List) {
        if (edge['source'] == 'agent:0' || edge['source'] == 'runtime:0') {
          edge['active'] = _deliveries.isEven;
        }
      }
      next['activity'] = {
        '0': {'working': _deliveries.isEven},
      };
    }
    final retained = retainMapSnapshot(_graph, next);
    if (!identical(retained, _graph)) {
      _accepted++;
      setState(() => _graph = retained);
    }
  }

  void _pointer() {
    // Dart binding events confined to this fixture's view. Never moves the OS pointer.
    final position = Offset(
      (400 + (_hovers.isEven ? 1 : 2)) * widget.options.zoom,
      42 + 250 * widget.options.zoom,
    );
    final view = View.of(context).viewId;
    if (!_pointerAdded) {
      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(
          device: _device,
          kind: PointerDeviceKind.mouse,
          position: position,
          viewId: view,
        ),
      );
      _pointerAdded = true;
    }
    GestureBinding.instance.handlePointerEvent(
      PointerHoverEvent(
        device: _device,
        kind: PointerDeviceKind.mouse,
        position: position,
        viewId: view,
      ),
    );
    _hovers++;
  }

  void _timings(List<FrameTiming> timings) {
    for (final t in timings) {
      _build.add(t.buildDuration.inMicroseconds);
      _raster.add(t.rasterDuration.inMicroseconds);
    }
  }

  @override
  void dispose() {
    _report.cancel();
    _deliver?.cancel();
    _hover?.cancel();
    if (_pointerAdded) {
      GestureBinding.instance.handlePointerEvent(
        const PointerRemovedEvent(
          device: _device,
          kind: PointerDeviceKind.mouse,
        ),
      );
    }
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: TooltipVisibility(
        visible: false,
        child: MapEditor(
          graph: _graph,
          saved: const {},
          onEdit: _noEdit,
          tr: _label,
          lightStyle: widget.options.style,
          animate: widget.options.lights ? 'all' : 'off',
          controller: _controller,
        ),
      ),
    ),
  );
}

String _label(String s) => s;
Future<void> _noEdit(Map<String, dynamic> _) async {}
Map<String, dynamic> _fixtureGraph() => {
  'nodes': [
    for (var i = 0; i < 13; i++)
      for (final (kind, col) in [('agent', 1), ('runtime', 2), ('model', 3)])
        {
          'id': '$kind:$i',
          'kind': kind,
          'column': col,
          'label': '$kind $i',
          'detail': 'Benchmark fixture',
        },
  ],
  'edges': [
    for (var i = 0; i < 13; i++) ...[
      {
        'source': 'agent:$i',
        'target': 'runtime:$i',
        'kind': 'uses',
        'active': i < 11,
        'activity': 'agent',
      },
      {
        'source': 'runtime:$i',
        'target': 'model:$i',
        'kind': 'serves',
        'active': i < 11,
        'activity': 'agent',
      },
      {
        'source': 'agent:$i',
        'target': 'model:$i',
        'kind': 'default',
        'active': i < 11,
        'activity': 'agent',
      },
    ],
  ],
  'activity': <String, dynamic>{},
};
