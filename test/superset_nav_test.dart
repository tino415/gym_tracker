import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/watch/superset_nav.dart';

SupersetSeq seq(List<({int sets, int? group})> exercises) {
  return SupersetSeq(
    exerciseCount: exercises.length,
    setCountAt: (i) => exercises[i].sets,
    supersetGroupAt: (i) => exercises[i].group,
  );
}

void main() {
  group('standalone (no supersets)', () {
    test('linear progression across exercises', () {
      final s = seq([
        (sets: 2, group: null),
        (sets: 2, group: null),
      ]);
      expect(s.nextAfter(0, 0), (eIdx: 0, sIdx: 1));
      expect(s.nextAfter(0, 1), (eIdx: 1, sIdx: 0));
      expect(s.nextAfter(1, 0), (eIdx: 1, sIdx: 1));
      expect(s.nextAfter(1, 1), isNull);
    });

    test('skips exercises with no sets', () {
      final s = seq([
        (sets: 1, group: null),
        (sets: 0, group: null),
        (sets: 1, group: null),
      ]);
      expect(s.nextAfter(0, 0), (eIdx: 2, sIdx: 0));
    });

    test('prev mirrors next', () {
      final s = seq([
        (sets: 2, group: null),
        (sets: 2, group: null),
      ]);
      expect(s.prevBefore(1, 1), (eIdx: 1, sIdx: 0));
      expect(s.prevBefore(1, 0), (eIdx: 0, sIdx: 1));
      expect(s.prevBefore(0, 1), (eIdx: 0, sIdx: 0));
      expect(s.prevBefore(0, 0), isNull);
    });
  });

  group('superset of equal-sized exercises', () {
    test('alternates A,B,C across each set index', () {
      final s = seq([
        (sets: 2, group: 1),
        (sets: 2, group: 1),
        (sets: 2, group: 1),
      ]);
      expect(s.nextAfter(0, 0), (eIdx: 1, sIdx: 0));
      expect(s.nextAfter(1, 0), (eIdx: 2, sIdx: 0));
      expect(s.nextAfter(2, 0), (eIdx: 0, sIdx: 1));
      expect(s.nextAfter(0, 1), (eIdx: 1, sIdx: 1));
      expect(s.nextAfter(1, 1), (eIdx: 2, sIdx: 1));
      expect(s.nextAfter(2, 1), isNull);
    });

    test('prev walks the same sequence in reverse', () {
      final s = seq([
        (sets: 2, group: 1),
        (sets: 2, group: 1),
        (sets: 2, group: 1),
      ]);
      expect(s.prevBefore(2, 1), (eIdx: 1, sIdx: 1));
      expect(s.prevBefore(1, 1), (eIdx: 0, sIdx: 1));
      expect(s.prevBefore(0, 1), (eIdx: 2, sIdx: 0));
      expect(s.prevBefore(0, 0), isNull);
    });
  });

  group('superset of uneven exercises', () {
    test('round 2: A has set 2, B does not — visit only A', () {
      // A: 3 sets, B: 2 sets, both in group 1.
      final s = seq([
        (sets: 3, group: 1),
        (sets: 2, group: 1),
      ]);
      expect(s.nextAfter(0, 0), (eIdx: 1, sIdx: 0));
      expect(s.nextAfter(1, 0), (eIdx: 0, sIdx: 1));
      expect(s.nextAfter(0, 1), (eIdx: 1, sIdx: 1));
      // After B.set1, the round-3 should skip B and land on A.set2.
      expect(s.nextAfter(1, 1), (eIdx: 0, sIdx: 2));
      expect(s.nextAfter(0, 2), isNull);
    });
  });

  group('mixed: superset followed by standalone', () {
    test('flows from group to the next exercise', () {
      final s = seq([
        (sets: 1, group: 1),
        (sets: 1, group: 1),
        (sets: 2, group: null),
      ]);
      expect(s.nextAfter(0, 0), (eIdx: 1, sIdx: 0));
      // Group of size 1 round is over; advance to standalone exercise.
      expect(s.nextAfter(1, 0), (eIdx: 2, sIdx: 0));
      expect(s.nextAfter(2, 0), (eIdx: 2, sIdx: 1));
      expect(s.nextAfter(2, 1), isNull);
    });

    test('two separate groups with the same group ID stay isolated', () {
      // A,B share group 1 (contiguous). C is standalone. D,E share group 1
      // again — should be treated as a separate superset because the run is
      // not contiguous.
      final s = seq([
        (sets: 1, group: 1),
        (sets: 1, group: 1),
        (sets: 1, group: null),
        (sets: 1, group: 1),
        (sets: 1, group: 1),
      ]);
      expect(s.nextAfter(1, 0), (eIdx: 2, sIdx: 0));
      expect(s.nextAfter(2, 0), (eIdx: 3, sIdx: 0));
      expect(s.nextAfter(3, 0), (eIdx: 4, sIdx: 0));
      expect(s.nextAfter(4, 0), isNull);
    });
  });
}
