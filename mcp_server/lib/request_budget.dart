/// A request is allowed only while every window has room for it, and then it
/// counts against all of them.
class RequestBudget {
  RequestBudget(this._windows);

  factory RequestBudget.perMinuteAndDay({
    required int perMinute,
    required int perDay,
    DateTime Function() now = DateTime.now,
  }) => RequestBudget([
    FixedWindow(perMinute, const Duration(minutes: 1), now),
    FixedWindow(perDay, const Duration(days: 1), now),
  ]);

  final List<FixedWindow> _windows;

  Duration? spend() {
    final waits = [for (final w in _windows) ?w.waitBeforeNext()];
    if (waits.isNotEmpty) return waits.reduce((a, b) => a > b ? a : b);
    for (final w in _windows) {
      w.count();
    }
    return null;
  }
}

class FixedWindow {
  FixedWindow(this.limit, this.length, this._now);

  final int limit;
  final Duration length;
  final DateTime Function() _now;
  DateTime? _start;
  var _used = 0;

  Duration? waitBeforeNext() {
    _rollOver();
    return _used < limit ? null : length - _now().difference(_start!);
  }

  void count() {
    _rollOver();
    _used++;
  }

  void _rollOver() {
    final now = _now();
    if (_start == null || now.difference(_start!) >= length) {
      _start = now;
      _used = 0;
    }
  }
}
