import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// An agent's network traffic: what it and the programs it started send and
/// receive (traffic.py). Read from the TCP connections of this user's own
/// processes (`ss -tinpeHn`: no root needed). Each sample adds what every
/// connection moved since the last one to the agent that owns it, per
/// destination and per program, with a few minutes of history. Only while
/// the app is open and asks; UDP (QUIC) is not counted.
const trafficEvery = Duration(seconds: 3);
const _history = 100; // samples kept (5 minutes)
const _maxOutput = 4 * 1024 * 1024;
const _maxSockets = 4000;
const _maxPlaces = 200;

const knownHosts = {
  'api.anthropic.com': 'Anthropic API',
  'claude.ai': 'Claude',
  'statsig.anthropic.com': 'Anthropic',
  'api.openai.com': 'OpenAI API',
  'chatgpt.com': 'ChatGPT',
  'auth.openai.com': 'OpenAI',
  'api.githubcopilot.com': 'GitHub Copilot',
  'api.github.com': 'GitHub',
  'generativelanguage.googleapis.com': 'Google Gemini API',
  'cloudcode-pa.googleapis.com': 'Google Gemini',
  'openrouter.ai': 'OpenRouter',
  'api.deepseek.com': 'DeepSeek API',
  'api.x.ai': 'xAI API',
  'api.mistral.ai': 'Mistral API',
  'ollama.com': 'Ollama cloud',
  'api.cursor.sh': 'Cursor',
  'registry.npmjs.org': 'npm registry',
  'pypi.org': 'PyPI',
  'huggingface.co': 'Hugging Face',
};

final _line = RegExp(r'^(\S+)\s+\d+\s+\d+\s+(\S+)\s+(\S+)\s*(.*)$');
final _user = RegExp(r'\("([^"]{1,64})",pid=(\d+),fd=\d+\)');
final _inode = RegExp(r'\bino:(\d+)');
final _sent = RegExp(r'\bbytes_sent:(\d+)');
final _received = RegExp(r'\bbytes_received:(\d+)');

final class Sock {
  Sock(this.local, this.remote, this.pid, this.comm, {this.inode = ''});
  final String local, remote, comm, inode;
  final int pid;
  int sent = 0, received = 0;

  void counters(String text) {
    if (_sent.firstMatch(text) case final m?) sent = int.parse(m[1]!);
    if (_received.firstMatch(text) case final m?) received = int.parse(m[1]!);
  }
}

/// Connections from `ss -tinpeHn`: a line per connection, its counters on
/// the indented line after it; only ones with an owner.
List<Sock> parseSs(String text) {
  final socks = <Sock>[];
  Sock? current;
  for (final line in const LineSplitter().convert(text).take(_maxSockets * 2)) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      current?.counters(line);
      continue;
    }
    current = null;
    final match = _line.firstMatch(line.trim());
    if (match == null) continue;
    final rest = match[4]!;
    final user = _user.firstMatch(rest);
    if (user == null) continue;
    current = Sock(
      match[2]!,
      match[3]!,
      int.parse(user[2]!),
      user[1]!,
      inode: _inode.firstMatch(rest)?[1] ?? '',
    )..counters(rest);
    socks.add(current);
  }
  return socks.take(_maxSockets).toList();
}

/// "[::1]:8080" / "1.2.3.4:443" / "[::ffff:1.2.3.4]:443" -> (address, port).
(String, int) splitAddress(String text) {
  final colon = text.lastIndexOf(':');
  final port = colon < 0 ? '' : text.substring(colon + 1);
  var host = (colon < 0 ? '' : text.substring(0, colon)).replaceAll(
    RegExp(r'^\[|\]$'),
    '',
  );
  if (host.startsWith('::ffff:')) host = host.substring(7);
  return (host.split('%').first, int.tryParse(port) ?? 0);
}

bool _private(InternetAddress ip) {
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        b[0] == 172 && b[1] >= 16 && b[1] < 32 ||
        b[0] == 192 && b[1] == 168 ||
        b[0] == 169 && b[1] == 254;
  }
  return b[0] & 0xfe == 0xfc || b[0] == 0xfe && b[1] & 0xc0 == 0x80;
}

/// Names for remote addresses: known online APIs, local LLMs by their port,
/// the local network. Lookups run in the background and are kept.
final class TrafficNames {
  final known = <String, String>{}; // address -> API name
  final reverse = <String, String>{}; // address -> host name ('' not known)
  DateTime? _knownAt;

  void refreshKnown() {
    final now = DateTime.now();
    if (_knownAt != null &&
        now.difference(_knownAt!) < const Duration(minutes: 10)) {
      return;
    }
    _knownAt = now;
    knownHosts.forEach((host, label) {
      InternetAddress.lookup(host).then((found) {
        for (final a in found.take(8)) {
          known.putIfAbsent(a.address, () => label);
        }
      }, onError: (_) {});
    });
  }

  void _lookUpLater(InternetAddress ip) {
    if (reverse.containsKey(ip.address) || reverse.length > 2000) return;
    reverse[ip.address] = '';
    ip.reverse().then((found) {
      final name = found.host == ip.address ? '' : found.host;
      reverse[ip.address] = name.length > 120 ? name.substring(0, 120) : name;
    }, onError: (_) {});
  }

  /// (name, kind): kind is api, local-llm, local, lan or web.
  (String, String) place(String remote, Map<int, String> localLlms) {
    final (address, port) = splitAddress(remote);
    final ip = InternetAddress.tryParse(address);
    if (ip == null) return (remote, 'web');
    if (ip.isLoopback) {
      return localLlms[port] != null
          ? (localLlms[port]!, 'local-llm')
          : ('localhost:$port', 'local');
    }
    if (_private(ip)) return (address, 'lan');
    if (known[address] case final name?) return (name, 'api');
    if (!reverse.containsKey(address)) _lookUpLater(ip);
    final name = reverse[address] ?? '';
    return (name.isEmpty ? address : name, 'web');
  }
}

final class Totals {
  int received = 0, sent = 0, connections = 0;
}

final class AgentTraffic {
  AgentTraffic(this.since);
  final double since; // seconds since the epoch
  int received = 0, sent = 0, connections = 0;
  final places = <(String, String), Totals>{};
  final programs = <String, Totals>{};
  final history = ListQueue<(double, double, double)>(); // time, in, out B/s

  (double, double) get rate =>
      history.isEmpty ? (0, 0) : (history.last.$2, history.last.$3);

  Map<String, dynamic> toJson() => {
    'since': since,
    'received': received,
    'sent': sent,
    'connections': connections,
    'rate_in': rate.$1,
    'rate_out': rate.$2,
    'places': [
      for (final e in places.entries)
        {
          'name': e.key.$1,
          'kind': e.key.$2,
          'received': e.value.received,
          'sent': e.value.sent,
          'connections': e.value.connections,
        },
    ],
    'programs': [
      for (final e in programs.entries)
        {'name': e.key, 'received': e.value.received, 'sent': e.value.sent},
    ],
    'history': [
      for (final h in history) [h.$1, h.$2, h.$3],
    ],
  };
}

final class TrafficMeter {
  TrafficMeter([TrafficNames? names]) : names = names ?? TrafficNames();
  final TrafficNames names;
  final stats = <String, AgentTraffic>{};
  var _last = <(int, String), (int, int)>{};
  double _when = 0;

  /// owners: pid -> (agent command, program name). now: seconds, monotonic.
  void update(
    List<Sock> socks,
    Map<int, (String, String)> owners,
    Map<int, String> localLlms, {
    required double now,
  }) {
    final dt = _when == 0 ? 0.0 : now - _when;
    _when = now;
    final seen = <(int, String), (int, int)>{};
    final moved = <String, (int, int)>{}, open = <String, int>{};
    final wall = DateTime.now().millisecondsSinceEpoch / 1000;
    for (final sock in socks) {
      final owner = owners[sock.pid];
      if (owner == null) continue;
      final (agent, program) = owner;
      final key = (
        sock.pid,
        sock.inode.isEmpty ? '${sock.local}>${sock.remote}' : sock.inode,
      );
      seen[key] = (sock.sent, sock.received);
      final (oldSent, oldReceived) = _last[key] ?? (0, 0);
      final sent = sock.sent - oldSent < 0 ? 0 : sock.sent - oldSent;
      final received = sock.received - oldReceived < 0
          ? 0
          : sock.received - oldReceived;
      final stat = stats.putIfAbsent(agent, () => AgentTraffic(wall));
      open[agent] = (open[agent] ?? 0) + 1;
      var place = names.place(sock.remote, localLlms);
      if (!stat.places.containsKey(place) && stat.places.length >= _maxPlaces) {
        place = ('…', 'web');
      }
      for (final totals in [
        stat.places.putIfAbsent(place, Totals.new),
        stat.programs.putIfAbsent(program, Totals.new),
      ]) {
        totals
          ..sent += sent
          ..received += received;
      }
      final (r, s) = moved[agent] ?? (0, 0);
      moved[agent] = (r + received, s + sent);
    }
    _last = seen;
    stats.forEach((agent, stat) {
      final (received, sent) = moved[agent] ?? (0, 0);
      stat
        ..received += received
        ..sent += sent
        ..connections = open[agent] ?? 0;
      for (final totals in stat.places.values) {
        totals.connections = 0;
      }
      if (dt > 0) {
        stat.history.add((wall, received / dt, sent / dt));
        if (stat.history.length > _history) stat.history.removeFirst();
      }
    });
    for (final sock in socks) {
      final owner = owners[sock.pid];
      if (owner == null) continue;
      final totals =
          stats[owner.$1]!.places[names.place(sock.remote, localLlms)];
      if (totals != null) totals.connections += 1;
    }
  }
}

/// traffic.agent_processes: pid -> (agent command, program name), each
/// agent's own processes and everything they started.
Map<int, (String, String)> agentProcesses(
  Map<String, List<int>> roots,
  Iterable<(int, String, List<String>)> processes,
  int Function(int pid) parentOf,
) {
  final ownerOf = {
    for (final e in roots.entries)
      for (final pid in e.value) pid: e.key,
  };
  final found = <int, (String, String)>{};
  for (final (pid, comm, argv) in processes) {
    var current = pid;
    for (var step = 0; current != 0 && step < 64; step++) {
      final owner = ownerOf[current];
      if (owner != null) {
        final name = argv.isEmpty ? comm : argv.first.split('/').last;
        final program = name.isEmpty ? comm : name;
        found[pid] = (
          owner,
          program.length > 60 ? program.substring(0, 60) : program,
        );
        break;
      }
      current = parentOf(current);
    }
  }
  return found;
}

/// The bounded output of ss; null when it cannot run.
String? readSs(String? program) {
  if (program == null) return null;
  try {
    final done = Process.runSync(program, const [
      '-tinpeHn',
    ], stdoutEncoding: const Utf8Codec(allowMalformed: true));
    final out = done.stdout as String;
    return out.length > _maxOutput ? out.substring(0, _maxOutput) : out;
  } on ProcessException {
    return null;
  }
}
