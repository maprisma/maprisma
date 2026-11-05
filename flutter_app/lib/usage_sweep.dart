/// The agents' usage records behind the batteries, renewed while the map is
/// open (agents.usage_refresh): each agent asked at most every [every] (the
/// core's USAGE_MAX_AGE, ten minutes; the core also skips a record that is
/// still fresh, and asks no program for one that is not due), one agent
/// after the other and one sweep at a time, in the background.
class UsageSweep {
  UsageSweep({
    this.every = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final Duration every;
  final DateTime Function() _now;
  final _asked = <String, DateTime>{};
  bool _running = false;

  /// A sweep is under way.
  bool get running => _running;

  /// Whether [command] may be asked now; when it may, it counts as asked.
  bool take(String command) {
    final now = _now(), last = _asked[command];
    if (last != null && now.difference(last) < every) return false;
    _asked[command] = now;
    return true;
  }

  /// Asks each due agent of [commands] in turn ([ask]: true when its record
  /// was renewed); nothing while another sweep runs. True when one was
  /// renewed.
  Future<bool> sweep(
    Iterable<String> commands,
    Future<bool> Function(String command) ask,
  ) async {
    if (_running) return false;
    _running = true;
    var renewed = false;
    try {
      for (final command in commands.toList()) {
        if (!take(command)) continue;
        try {
          if (await ask(command)) renewed = true;
        } catch (_) {
          // That record stays as it was; the others are still asked.
        }
      }
    } finally {
      _running = false;
    }
    return renewed;
  }
}
