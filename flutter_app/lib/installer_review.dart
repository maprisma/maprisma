import 'package:flutter/material.dart';
import 'providers_view.dart' show modelSize;
import 'task_card.dart';

/// What the user chose on the installer review: the build and the service.
class InstallerChoice {
  InstallerChoice(this.build);
  String build;
  bool startNow = false;
  bool startAtLogin = false;
}

/// The reviewed first install of a program (installers.preview): the release
/// and its files, where it goes, the hardware build and its user service.
class InstallerReview extends StatefulWidget {
  const InstallerReview({
    super.key,
    required this.preview,
    required this.choice,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> preview;
  final InstallerChoice choice;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  State<InstallerReview> createState() => _InstallerReviewState();
}

const _buildHelp = {
  'vulkan': 'Vulkan: any AMD or NVIDIA card, nothing else needed.',
  'rocm': 'ROCm: AMD, needs ROCm installed (/opt/rocm).',
  'cuda': 'CUDA: NVIDIA.',
  'cpu': 'CPU only: slow, for a test.',
};

class _InstallerReviewState extends State<InstallerReview> {
  @override
  Widget build(BuildContext context) {
    final p = widget.preview, tr = widget.tr, choice = widget.choice;
    final builds = [
      for (final b in p['builds'] as List? ?? const [])
        ((b as List)[0] as String, b[1] as String),
    ];
    final files = (p['files'] as List? ?? const []).cast<Map>();
    final gpu = p['gpu'] is Map ? p['gpu'] as Map : const {};
    final changed = choice.build != p['build'];
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 160, child: Text(tr(label))),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
    return TaskReview(
      title: Text(
        tr('Install {0}?').replaceAll('{0}', '${p['name']} · ${p['version']}'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              'The download is checked against the checksum its release lists; nothing of it runs while it is installed.',
            ),
          ),
          const SizedBox(height: 16),
          for (final f in files)
            fact('Download', '${f['name']} · ${modelSize(f['size'] as num)}'),
          fact(
            'Program folder',
            '${p['folder']}\n${tr('Where the program goes. Each version gets its own folder in it.')}',
          ),
          if (p['models'] is String) fact('Model folder', '${p['models']}'),
          if (gpu.isNotEmpty && gpu['vendor'] != 'cpu')
            fact('GPU', '${gpu['name'] ?? gpu['vendor']}'),
          if (builds.length > 1) ...[
            const SizedBox(height: 8),
            Text(tr('Build'), style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: choice.build,
              onChanged: (value) =>
                  setState(() => choice.build = value ?? choice.build),
              child: Column(
                children: [
                  for (final (key, label) in builds)
                    RadioListTile<String>(
                      value: key,
                      title: Text(label),
                      subtitle: _buildHelp.containsKey(key)
                          ? Text(tr(_buildHelp[key]!))
                          : null,
                    ),
                ],
              ),
            ),
          ],
          if (p['has_service'] == true) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              value: choice.startNow,
              title: Text(tr('Start now')),
              subtitle: Text(tr('Start it as soon as it is installed.')),
              onChanged: (value) => setState(() => choice.startNow = value),
            ),
            SwitchListTile(
              value: choice.startAtLogin,
              title: Text(tr('Start at login')),
              subtitle: Text(
                tr('Start it with every login (its user service).'),
              ),
              onChanged: (value) => setState(() => choice.startAtLogin = value),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: widget.onConfirm,
          // Another build is looked up again before anything is installed.
          child: Text(tr(changed ? 'Change' : 'Install')),
        ),
      ],
    );
  }
}
