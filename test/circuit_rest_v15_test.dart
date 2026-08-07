import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/circuit_rest_v15.dart';

/// The v14 → v15 rest translation. It runs once per install and rewrites rows
/// in place, so the rule is tested here rather than discovered on a device.
void main() {
  GroupRestRow row(
    String syncId, {
    String parent = 'r1',
    int? group,
    required int rest,
  }) => (syncId: syncId, parent: parent, group: group, restSeconds: rest);

  test('a two-member group moves the round rest onto the last member', () {
    // Old behaviour: one rest per round, valued from A, taken after B.
    final plan = translateCircuitRestV15([
      row('a', group: 1, rest: 90),
      row('b', group: 1, rest: 90),
    ]);
    expect(plan.restBySyncId, {'a': 0});
    expect(plan.parents, {'r1'});
  });

  test('the last member takes the first member\'s value, not its own', () {
    // B's stale 60 is meaningless today — only A's 120 was ever used.
    final plan = translateCircuitRestV15([
      row('a', group: 1, rest: 120),
      row('b', group: 1, rest: 60),
    ]);
    expect(plan.restBySyncId, {'a': 0, 'b': 120});
  });

  test('a longer circuit zeroes every member but the last', () {
    final plan = translateCircuitRestV15([
      row('a', group: 1, rest: 75),
      row('b', group: 1, rest: 90),
      row('c', group: 1, rest: 90),
    ]);
    expect(plan.restBySyncId, {'a': 0, 'b': 0, 'c': 75});
  });

  test('standalone exercises are left alone', () {
    final plan = translateCircuitRestV15([
      row('a', rest: 90),
      row('b', rest: 60),
    ]);
    expect(plan.restBySyncId, isEmpty);
    expect(plan.parents, isEmpty);
  });

  test('a lone member of a group already rests after its own set', () {
    // A run of one is not a circuit: old and new semantics agree, so touching
    // it would change how the routine runs rather than preserve it.
    final plan = translateCircuitRestV15([row('a', group: 1, rest: 90)]);
    expect(plan.restBySyncId, isEmpty);
  });

  test('groups are delimited by parent as well as by group id', () {
    // Same group number under two routines is two circuits, not one — without
    // the parent check r1's rest would leak onto r2's member.
    final plan = translateCircuitRestV15([
      row('a', parent: 'r1', group: 1, rest: 30),
      row('b', parent: 'r2', group: 1, rest: 90),
    ]);
    expect(plan.restBySyncId, isEmpty);
  });

  test('adjacent groups under one parent are translated independently', () {
    final plan = translateCircuitRestV15([
      row('a', group: 1, rest: 45),
      row('b', group: 1, rest: 90),
      row('c', group: 2, rest: 120),
      row('d', group: 2, rest: 90),
    ]);
    expect(plan.restBySyncId, {'a': 0, 'b': 45, 'c': 0, 'd': 120});
  });

  test('a standalone exercise between two groups does not join them', () {
    final plan = translateCircuitRestV15([
      row('a', group: 1, rest: 45),
      row('b', group: 1, rest: 90),
      row('mid', rest: 90),
      row('c', group: 1, rest: 30),
      row('d', group: 1, rest: 90),
    ]);
    // Two separate circuits that happen to share a group id, split by `mid`.
    expect(plan.restBySyncId, {'a': 0, 'b': 45, 'c': 0, 'd': 30});
    expect(plan.restBySyncId.containsKey('mid'), isFalse);
  });

  test('an already-translated group is a no-op, so re-running is safe', () {
    final plan = translateCircuitRestV15([
      row('a', group: 1, rest: 0),
      row('b', group: 1, rest: 0),
    ]);
    expect(plan.restBySyncId, isEmpty);
    expect(plan.parents, isEmpty);
  });
}
