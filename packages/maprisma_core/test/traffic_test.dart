import 'package:maprisma_core/src/traffic.dart';
import 'package:test/test.dart';

/// The behaviour of traffic.py (tests/test_traffic.py).
void main() {
  const ss =
      'ESTAB 0 0 192.168.178.20:41000 160.79.104.10:443 '
      'users:(("claude",pid=100,fd=23)) ino:5001 sk:1\n'
      '\t cubic bytes_sent:2000 bytes_received:50000 rcv_space:1\n'
      'ESTAB 0 0 127.0.0.1:41001 127.0.0.1:8080 '
      'users:(("node",pid=200,fd=9)) ino:5002 sk:2\n'
      '\t cubic bytes_sent:10 bytes_received:20\n'
      'ESTAB 0 0 127.0.0.1:41002 127.0.0.1:9000\n';

  test('parses connections with their owner and counters', () {
    final socks = parseSs(ss);
    expect(socks.length, 2);
    expect(socks.first.pid, 100);
    expect(socks.first.comm, 'claude');
    expect(socks.first.inode, '5001');
    expect(socks.first.sent, 2000);
    expect(socks.first.received, 50000);
  });

  test('addresses', () {
    expect(splitAddress('[::1]:8080'), ('::1', 8080));
    expect(splitAddress('1.2.3.4:443'), ('1.2.3.4', 443));
    expect(splitAddress('[::ffff:1.2.3.4]:443'), ('1.2.3.4', 443));
  });

  test('places', () {
    final names = TrafficNames()..known['160.79.104.10'] = 'Anthropic API';
    final llms = {8080: 'llama.cpp'};
    expect(names.place('127.0.0.1:8080', llms), ('llama.cpp', 'local-llm'));
    expect(names.place('127.0.0.1:9000', {}), ('localhost:9000', 'local'));
    expect(names.place('192.168.178.63:8009', {}), ('192.168.178.63', 'lan'));
    expect(names.place('160.79.104.10:443', {}), ('Anthropic API', 'api'));
  });

  test('rates, totals and gone connections', () {
    final names = TrafficNames()..known['160.79.104.10'] = 'Anthropic API';
    final meter = TrafficMeter(names);
    final socks = parseSs(ss);
    const owners = {100: ('claude', 'claude'), 200: ('claude', 'node')};
    const llms = {8080: 'llama.cpp'};
    meter.update(socks, owners, llms, now: 10);
    final stat = meter.stats['claude']!;
    expect(stat.received, 50020);
    expect(stat.connections, 2);
    expect(stat.rate, (0.0, 0.0));
    expect(stat.programs.keys, containsAll(['claude', 'node']));

    socks.first.received += 3000;
    meter.update(socks, owners, llms, now: 13);
    expect(stat.received, 53020);
    expect(stat.rate, (1000.0, 0.0));

    meter.update([], owners, llms, now: 16);
    expect(stat.received, 53020);
    expect(stat.connections, 0);
    expect(stat.rate, (0.0, 0.0));
    expect(stat.toJson()['history'], hasLength(2));
  });

  test('a program belongs to the agent that started it', () {
    final found = agentProcesses(
      {
        'claude': [100],
      },
      [
        (100, 'claude', ['/usr/bin/claude']),
        (200, 'node', ['/usr/bin/node', 'server.js']),
        (300, 'bash', ['bash']),
      ],
      (pid) => const {200: 100, 300: 1}[pid] ?? 0,
    );
    expect(found, {100: ('claude', 'claude'), 200: ('claude', 'node')});
  });
}
