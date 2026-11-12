import 'package:gym_tracker_mcp/request_budget.dart';
import 'package:test/test.dart';

void main() {
  var clock = DateTime(2026, 11, 8);
  RequestBudget budget() =>
      RequestBudget.perMinuteAndDay(perMinute: 2, perDay: 3, now: () => clock);

  setUp(() => clock = DateTime(2026, 11, 8));

  test('the minute window refills after a minute', () {
    final b = budget();
    expect(b.spend(), isNull);
    clock = clock.add(const Duration(seconds: 15));
    expect(b.spend(), isNull);
    expect(b.spend(), const Duration(seconds: 45));

    clock = clock.add(const Duration(seconds: 45));
    expect(b.spend(), isNull);
  });

  test('the day window holds once spent, whatever the minute allows', () {
    final b = budget();
    for (var i = 0; i < 3; i++) {
      expect(b.spend(), isNull);
      clock = clock.add(const Duration(minutes: 1));
    }
    expect(b.spend(), const Duration(hours: 23, minutes: 57));

    clock = clock.add(const Duration(hours: 23, minutes: 57));
    expect(b.spend(), isNull);
  });

  test('a refused request counts against no window', () {
    final b = budget();
    b
      ..spend()
      ..spend();
    expect(b.spend(), isNotNull);
    clock = clock.add(const Duration(minutes: 1));
    expect(b.spend(), isNull, reason: 'the day had one request left');
  });
}
