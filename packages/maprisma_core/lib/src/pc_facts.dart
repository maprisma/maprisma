import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'installers.dart' show Gpu, detectGpu;
import 'llm_tuning.dart' show stacksHere;
import 'model_hub.dart' show boundedOutput;
import 'model_guard.dart' show GpuUsage;
import 'provider_scans.dart';
import 'scan_files.dart';

/// Hardware only. Inject roots and GPU readings in tests; never starts a model.
final class PcFacts {
  PcFacts(
    this.files, {
    this.proc = '/proc',
    this.cpu = '/sys/devices/system/cpu',
    Future<Gpu> Function()? gpu,
    this.usage,
    this.cardList,
  }) : gpu = gpu ?? detectGpu;
  final ScanFiles files;
  final String proc, cpu;
  final Future<Gpu> Function() gpu;
  final GpuUsage? usage;
  final Future<List<Map<String, dynamic>>> Function()? cardList;

  static Map<String, int> memory(String text) => {
    for (final m in RegExp(
      r'^(MemTotal|MemAvailable):\s+(\d+)\s+kB',
      multiLine: true,
    ).allMatches(text))
      m[1]!: int.parse(m[2]!) * 1024,
  };

  static int physicalCores(String root, int logical) {
    final cores = <String>{};
    try {
      for (final entry in Directory(root).listSync(followLinks: false)) {
        if (!RegExp(r'^cpu\d+$').hasMatch(p.basename(entry.path))) continue;
        try {
          final package = File(
            '${entry.path}/topology/physical_package_id',
          ).readAsStringSync().trim();
          final core = File(
            '${entry.path}/topology/core_id',
          ).readAsStringSync().trim();
          if (int.tryParse(package) != null && int.tryParse(core) != null) {
            cores.add('$package:$core');
          }
        } on FileSystemException {
          /* Offline CPU. */
        }
      }
    } on FileSystemException {
      /* Fall back to logical cores. */
    }
    return cores.isEmpty ? math.max(1, logical) : cores.length;
  }

  Future<List<Map<String, dynamic>>> _cards(Gpu gpu) async {
    if (gpu.vendor == 'nvidia') {
      final (out, ok) = await boundedOutput(
        [
          'nvidia-smi',
          '--query-gpu=name,memory.total,compute_cap,pci.bus_id',
          '--format=csv,noheader,nounits',
        ],
        maxBytes: 8192,
        timeout: const Duration(seconds: 2),
        environment: files.identity.environment,
      );
      if (ok) {
        return [
          for (final line in String.fromCharCodes(out).split('\n'))
            if (line.split(',').length == 4)
              {
                'name': line.split(',')[0].trim(),
                'total':
                    ((double.tryParse(line.split(',')[1].trim()) ?? 0) *
                            1024 *
                            1024)
                        .toInt(),
                'compute_capability': line.split(',')[2].trim(),
                'slot': line.split(',')[3].trim(),
              },
        ];
      }
    }
    final root =
        files.identity.environment['MAPRISMA_SCAN_GPU'] ?? '/sys/class/drm';
    String text(String path) =>
        files.text(
          path,
          limit: 4096,
          portion: 'head',
          follow: true,
          allowRootOwned: true,
        ) ??
        '';
    return [
      for (final card in files.list(root, limit: 256, allowRootOwned: true))
        if (RegExp(r'^card\d+$').hasMatch(p.basename(card)))
          {
            'name': gpu.name,
            'total':
                int.tryParse(text('$card/device/mem_info_vram_total').trim()) ??
                0,
            'slot':
                RegExp(
                  r'PCI_SLOT_NAME=(\S+)',
                ).firstMatch(text('$card/device/uevent'))?[1] ??
                p.basename(card),
          },
    ];
  }

  Future<Map<String, dynamic>> collect(
    RuntimeRecord rt, {
    int? providerVram,
  }) async {
    final card = await gpu();
    final scan = ProviderScans(files);
    final use = usage ?? GpuUsage(files, scan);
    final (used, total, _) = await use.totals();
    // procVram is amdgpu-only: NVIDIA gets its total as the baseline.
    var other = 0;
    final driver = use.gpuDir == null
        ? ''
        : files.text(
                '${use.gpuDir}/uevent',
                limit: 4096,
                portion: 'head',
                follow: true,
                allowRootOwned: true,
              ) ??
              '';
    if (card.vendor == 'amd' && driver.contains('DRIVER=amdgpu')) {
      final pids = use.runtimePids(scan.processes())[rt.key] ?? const <int>{};
      final own =
          providerVram ?? pids.fold<int>(0, (n, pid) => n + use.procVram(pid));
      other = math.max(0, used - own);
    }
    final vram = math.max(card.vram, total);
    String mem = '';
    try {
      mem = File('$proc/meminfo').readAsStringSync();
    } on FileSystemException {
      /* Unknown. */
    }
    final ram = memory(mem);
    final cards = await (cardList ?? () => _cards(card))();
    final nvidia = [...cards]
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
    final best = card.vendor == 'nvidia' ? nvidia.firstOrNull : null;
    final totalVram = best?['total'] is int
        ? math.max(vram, best!['total'] as int)
        : vram;
    final capability =
        double.tryParse('${best?['compute_capability'] ?? ''}') ?? 0;
    return {
      'gpu': best?['name'] ?? card.name,
      'vendor': card.vendor,
      'gpu_count': card.vendor == 'nvidia' && cards.isNotEmpty
          ? cards.length
          : card.count,
      'cards': cards,
      'fp8_supported':
          card.vendor == 'nvidia' && capability >= 8.9 ||
          card.vendor == 'amd' &&
              RegExp(r'\bMI3\d\d', caseSensitive: false).hasMatch(card.name),
      'vram_total': totalVram,
      'other_used': other.clamp(0, totalVram),
      'vram_available': math.max(0, totalVram - other),
      'ram_total': ram['MemTotal'] ?? 0,
      'ram_available': ram['MemAvailable'] ?? 0,
      'physical_cores': physicalCores(cpu, Platform.numberOfProcessors),
      'logical_cores': Platform.numberOfProcessors,
      'stacks': stacksHere(files.identity.environment['PATH']),
    };
  }
}
