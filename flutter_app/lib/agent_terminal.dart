import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'backend.dart';

class AgentTerminal extends ChangeNotifier {
  AgentTerminal(
    this.backend,
    this.id,
    this.command,
    this.path, {
    required this.tr,
  }) {
    terminal.onOutput = (text) {
      final bytes = utf8.encode(text);
      if (_input.length + bytes.length > 256 * 1024) {
        terminal.write(
          '\r\n[${tr('Input buffer full; paste was rejected')}]\r\n',
        );
        return;
      }
      _input.addAll(bytes);
      _pump();
    };
    terminal.onResize = (cols, rows, _, _) {
      _size = (cols, rows);
      _pump();
    };
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _pump());
  }

  final Backend backend;
  final String Function(String) tr;
  final String id;
  final String command;
  final String path;
  final terminal = Terminal(maxLines: 10000);
  final selection = TerminalController();
  final _input = <int>[];
  late final Timer _timer;
  (int, int)? _size;
  bool ended = false;
  bool failed = false;
  bool _pumping = false;
  bool _disposed = false;
  DateTime? _retryAfter;

  Future<void> _pump() async {
    if (_pumping ||
        ended ||
        _disposed ||
        (_retryAfter?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _pumping = true;
    try {
      final client = CoreClient(backend);
      final size = _size;
      if (size != null && size.$1 >= 2 && size.$2 >= 2) {
        await client.sessionsResize(session: id, cols: size.$1, rows: size.$2);
        if (_size == size) _size = null;
      }
      if (_input.isNotEmpty) {
        final length = _input.length > 4096 ? 4096 : _input.length;
        final reply = await client.sessionsWrite(
          session: id,
          data: base64Encode(_input.sublist(0, length)),
        );
        final accepted = reply['accepted'] as int;
        if (accepted < 0 || accepted > length) {
          throw StateError('Invalid input acknowledgement');
        }
        _input.removeRange(0, accepted);
        if (reply['ended'] == true) _input.clear();
      }
      final reply = await client.sessionsRead(session: id);
      if (_disposed) return;
      terminal.write(reply['text'] as String);
      if (reply['verification_failed'] == true) {
        failed = true;
        terminal.write('\r\n${tr('The action could not be completed.')}\r\n');
      }
      if (reply['ended'] == true) {
        ended = true;
        _timer.cancel();
        notifyListeners();
      }
    } catch (_) {
      if (!_disposed) {
        failed = !backend.isConnected;
        _retryAfter = DateTime.now().add(const Duration(seconds: 1));
        if (failed) {
          ended = true;
          terminal.write(
            '\r\n[${tr('Service disconnected; agent session ended')}]\r\n',
          );
          _timer.cancel();
        }
        notifyListeners();
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> stop() async {
    await CoreClient(backend).sessionsStop(session: id);
    ended = true;
    _timer.cancel();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    selection.dispose();
    super.dispose();
  }
}

class AgentTerminalView extends StatelessWidget {
  const AgentTerminalView({
    super.key,
    required this.session,
    required this.keys,
    required this.tr,
    required this.onBack,
    required this.onStop,
    this.onScreenshot,
  });

  final AgentTerminal session;
  final String Function(String) tr;
  final VoidCallback onBack;
  final VoidCallback onStop;

  /// Where the keyboard goes; the page asks for it after a tab was clicked.
  final FocusNode keys;

  /// F9 belongs to the program in the terminal: the footer's symbol instead.
  final VoidCallback? onScreenshot;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              IconButton(
                tooltip: tr('Back'),
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  '${session.command} · ${session.path}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (session.failed) const Icon(Icons.error_outline),
              TextButton(
                onPressed: onStop,
                child: Text(tr(session.ended ? 'Close' : 'Stop')),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: _TakesKeys(
              keys,
              child: TerminalView(
                session.terminal,
                controller: session.selection,
                focusNode: keys,
                onSecondaryTapDown: (_, _) async {
                  final selected = session.selection.selection;
                  if (selected != null) {
                    final text = session.terminal.buffer.getText(selected);
                    session.selection.clearSelection();
                    await Clipboard.setData(ClipboardData(text: text));
                  } else {
                    final clipboard = await Clipboard.getData('text/plain');
                    if (clipboard?.text != null) {
                      session.terminal.paste(clipboard!.text!);
                    }
                  }
                },
              ),
            ),
          ),
        ),
        if (onScreenshot != null)
          Align(
            alignment: Alignment.centerRight,
            // A click leaves the keyboard with the terminal.
            child: ExcludeFocus(
              child: IconButton(
                key: const ValueKey('terminal-screenshot'),
                tooltip: tr('Save a screenshot'),
                onPressed: onScreenshot,
                icon: const Icon(Icons.photo_camera_outlined),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A new terminal takes the keyboard from whatever had it: `autofocus` alone
/// leaves it there.
class _TakesKeys extends StatefulWidget {
  const _TakesKeys(this.keys, {required this.child});

  final FocusNode keys;
  final Widget child;

  @override
  State<_TakesKeys> createState() => _TakesKeysState();
}

class _TakesKeysState extends State<_TakesKeys> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.keys.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
