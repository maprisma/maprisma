import 'adapters.dart';
import 'desktop.dart' show whichIn;
import 'system_help.dart' show guardBackground;

/// local_helper: an agent connected to a local LLM that answers AI help
/// questions with one of that LLM's models, on this PC, without the web and
/// without tokens of a plan. Any agent whose adapter has an advise fact (one
/// question, offline, no tools, the model given by options) and what closes
/// it in can be it; which agent, provider and model is the user's choice
/// (Settings › AI help), and the app suggests one: the largest chat model the
/// graphics card holds.

/// Model names that are not chat models: speech, embeddings, rerankers,
/// tokenizers, vision parts.
final notChat = RegExp(
  r'tts|whisper|embed|rerank|tokenizer|mmproj|clip|vae|diffusion|flux|sdxl|'
  r'stable-?diffusion|speech|asr|vision-encoder',
  caseSensitive: false,
);
const gpuShare = 0.85;
const minBytes = 2 * 1024 * 1024 * 1024;

typedef HelperCandidate = ({
  String agent,
  String provider,
  String runtime,
  String model,
  int size,
});

Map<String, String> helperKey(HelperCandidate c) => {
  'agent': c.agent,
  'provider': c.provider,
  'model': c.model,
};

/// advisers: installed agents that can be the helper (an advise fact and
/// what closes them in, the program on PATH).
List<Adapter> advisers(
  List<Adapter> adapters,
  Set<String> installed,
  String? path,
) => [
  for (final a in adapters)
    if (a.facts.containsKey('advise') &&
        a.facts.containsKey('closed') &&
        installed.contains(a.command) &&
        whichIn(a.command, path) != null)
      a,
];

/// candidates: every (agent, local LLM it is connected to, chat model of
/// that LLM). providersOf: the agent's providers (name, local, runtime);
/// runtimes: (key, name, installed, models); sizeOf: a model's file size.
List<HelperCandidate> helperCandidates(
  List<Adapter> agents,
  List<Map> Function(Adapter) providersOf,
  List<Map> runtimes,
  int Function(Map runtime, String model) sizeOf,
) {
  final found = <HelperCandidate>[];
  for (final agent in agents) {
    List<Map> providers;
    try {
      providers = providersOf(agent);
    } on Object {
      continue;
    }
    for (final provider in providers) {
      if (provider['local'] != true) continue;
      final rt = runtimes
          .where(
            (r) =>
                r['installed'] == true &&
                (provider['runtime'] == r['name'] ||
                    provider['runtime'] == r['key']),
          )
          .firstOrNull;
      if (rt == null) continue;
      for (final model in rt['models'] as List? ?? const []) {
        final name = '$model';
        if (notChat.hasMatch(name)) continue;
        int size;
        try {
          size = sizeOf(rt, name);
        } on Object {
          size = 0;
        }
        found.add((
          agent: agent.command,
          provider: '${provider['name']}',
          runtime: '${rt['key']}',
          model: name,
          size: size,
        ));
      }
    }
  }
  return found;
}

/// suggest: the largest chat model that fits the card (with room for its
/// context); without sizes or a card the first one.
HelperCandidate? suggestHelper(List<HelperCandidate> found, int vram) {
  if (found.isEmpty) return null;
  final limit = vram != 0 ? vram * gpuShare : 0;
  final sized = [
    for (final c in found)
      if (c.size >= minBytes && (limit == 0 || c.size <= limit)) c,
  ];
  if (sized.isNotEmpty) {
    var best = sized.first;
    for (final c in sized) {
      if (c.size > best.size) best = c;
    }
    return best;
  }
  return found.any((c) => c.size != 0) ? null : found.first;
}

/// chosen: the helper confirmed in Settings, while it is still there.
HelperCandidate? chosenHelper(List<HelperCandidate> found, dynamic setting) {
  if (setting is! Map) return null;
  return found
      .where(
        (c) =>
            c.agent == setting['agent'] &&
            c.provider == setting['provider'] &&
            c.model == setting['model'],
      )
      .firstOrNull;
}

/// advise_argv: (argv, output format) for one question to the helper; the
/// prompt goes on stdin.
(List<String>, String) adviseArgv(
  Adapter adapter,
  HelperCandidate c,
  Map<String, String> env,
  String home,
) {
  final advise = adapter.table('advise');
  final argv = [for (final a in advise['argv'] as List) '$a'];
  final model = [for (final a in advise['model'] as List) '$a'];
  final fill = {'{model}': c.model, '{provider}': c.provider};
  final full = [
    whichIn(c.agent, env['PATH']) ?? c.agent,
    ...argv.skip(1),
    for (final a in model) fill[a] ?? a,
  ];
  return (
    guardBackground(adapter, c.agent, full, env, home),
    '${advise['output'] ?? 'text'}',
  );
}

/// label: "Pi · llama.cpp · gemma-4-26B".
String helperLabel(HelperCandidate c, String agentName, String runtimeName) => [
  agentName,
  runtimeName.isNotEmpty ? runtimeName : c.provider,
  c.model,
].where((s) => s.isNotEmpty).join(' · ');
