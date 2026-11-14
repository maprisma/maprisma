import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_core/maprisma_core.dart'
    show boundedClipboardText, maxTerminalPaste;
import 'package:xterm/xterm.dart';

import 'app_look.dart' show AppSpace, WindowHeader;
import 'app_theme.dart' show monoFont;
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

  var _pasting = false;

  /// The clipboard's text through the bounded read (wl-paste, at most 1 MiB
  /// and 2 s: core boundedClipboardText), then into the terminal with
  /// bracketed paste. One at a time: a paste while one is read is dropped.
  Future<void> pasteClipboard() async {
    if (_pasting || ended) return;
    _pasting = true;
    try {
      final text = await boundedClipboardText();
      if (text == null) {
        terminal.write(
          '\r\n[${tr('Clipboard text is too long to paste (max {0} KiB)').replaceAll('{0}', '${maxTerminalPaste ~/ 1024}')}]\r\n',
        );
      } else if (text.isNotEmpty && !ended) {
        terminal.paste(text);
      }
    } finally {
      _pasting = false;
    }
  }

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

  /// F12 belongs to the program in the terminal: the footer's symbol instead.
  final VoidCallback? onScreenshot;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Column(
      children: [
        WindowHeader(
          title: session.command,
          subtitle: session.path,
          tr: tr,
          backKey: const ValueKey('terminal-back'),
          onBack: onBack,
          actions: [
            if (session.failed)
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
            OutlinedButton(
              key: const ValueKey('terminal-stop'),
              onPressed: onStop,
              child: Text(tr(session.ended ? 'Close' : 'Stop')),
            ),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.sm),
            child: _TakesKeys(
              keys,
              child: TerminalView(
                session.terminal,
                controller: session.selection,
                focusNode: keys,
                // The desktop's monospace font (xterm's fallbacks stay).
                textStyle: TerminalStyle(fontFamily: monoFont(context)),
                // Paste only through the bounded read (AgentTerminal.pasteClipboard),
                // never xterm's own, which takes the whole clipboard offer.
                shortcuts: terminalShortcuts(session),
                onSecondaryTapDown: (_, _) async {
                  final selected = session.selection.selection;
                  if (selected != null) {
                    final text = session.terminal.buffer.getText(selected);
                    session.selection.clearSelection();
                    await Clipboard.setData(ClipboardData(text: text));
                  } else {
                    await session.pasteClipboard();
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
/// xterm's keys (copy, select all) with paste — Ctrl+V and Ctrl+Shift+V —
/// going to the bounded read instead of xterm's unbounded one.
Map<ShortcutActivator, Intent> terminalShortcuts(AgentTerminal session) => {
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyA, control: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyV, control: true):
      VoidCallbackIntent(session.pasteClipboard),
  const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      VoidCallbackIntent(session.pasteClipboard),
};

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
