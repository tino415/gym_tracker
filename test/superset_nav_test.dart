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

  group('nextForCompletion (completion-aware advance)', () {
    // Helper: completion set as a record set of "e:s" strings.
    bool Function(int, int) done(Set<String> completed) =>
        (e, s) => completed.contains('$e:$s');

    test('no skips: standalone flow matches planned order', () {
      final s = seq([
        (sets: 2, group: null),
        (sets: 2, group: null),
      ]);
      expect(s.nextForCompletion(0, 0, done({})), (eIdx: 0, sIdx: 1));
      expect(
        s.nextForCompletion(0, 1, done({'0:0'})),
        (eIdx: 1, sIdx: 0),
      );
      expect(
        s.nextForCompletion(1, 1, done({'0:0', '0:1', '1:0'})),
        isNull,
      );
    });

    test('no skips: superset alternation is preserved', () {
      final s = seq([
        (sets: 2, group: 1),
        (sets: 2, group: 1),
      ]);
      // A.set0 done → B.set0 (same round).
      expect(s.nextForCompletion(0, 0, done({})), (eIdx: 1, sIdx: 0));
      // B.set0 done (A.set0 done) → A.set1 (next round).
      expect(
        s.nextForCompletion(1, 0, done({'0:0'})),
        (eIdx: 0, sIdx: 1),
      );
    });

    test('skipped superset mate: stay in current exercise until done', () {
      final s = seq([
        (sets: 3, group: 1),
        (sets: 3, group: 1),
      ]);
      // User skipped A.set0 and completed B.set0 — alternation would bounce
      // to A.set1, but A has skipped work behind it, so stay in B.
      expect(s.nextForCompletion(1, 0, done({})), (eIdx: 1, sIdx: 1));
      expect(
        s.nextForCompletion(1, 1, done({'1:0'})),
        (eIdx: 1, sIdx: 2),
      );
      // B finished → return to the skipped exercise's first hole.
      expect(
        s.nextForCompletion(1, 2, done({'1:0', '1:1'})),
        (eIdx: 0, sIdx: 0),
      );
    });

    test('three-member group: alternation continues among non-skipped mates',
        () {
      final s = seq([
        (sets: 2, group: 1),
        (sets: 2, group: 1),
        (sets: 2, group: 1),
      ]);
      // A.set0 skipped; B.set0 done → C.set0 (same round, no hole in C).
      expect(s.nextForCompletion(1, 0, done({})), (eIdx: 2, sIdx: 0));
      // C.set0 done → alternation would go A.set1 (hole behind) → B.set1.
      expect(
        s.nextForCompletion(2, 0, done({'1:0'})),
        (eIdx: 1, sIdx: 1),
      );
    });

    test('standalone exercise skipped entirely: return after current is done',
        () {
      final s = seq([
        (sets: 2, group: null),
        (sets: 2, group: null),
        (sets: 2, group: null),
      ]);
      // A skipped; user finishes B → back to A.set0, not onward to C.
      expect(
        s.nextForCompletion(1, 1, done({'1:0'})),
        (eIdx: 0, sIdx: 0),
      );
    });

    test('advance skips sets that are already completed', () {
      final s = seq([
        (sets: 3, group: null),
      ]);
      // set1 was already logged earlier; completing set0 jumps to set2.
      expect(
        s.nextForCompletion(0, 0, done({'0:1'})),
        (eIdx: 0, sIdx: 2),
      );
    });

    test('forward exhausted: wraps to earliest hole in walker order', () {
      final s = seq([
        (sets: 1, group: null),
        (sets: 1, group: null),
        (sets: 1, group: null),
      ]);
      // A and B skipped; completing the last set wraps to A.set0.
      expect(s.nextForCompletion(2, 0, done({})), (eIdx: 0, sIdx: 0));
    });

    test('everything complete returns null', () {
      final s = seq([
        (sets: 1, group: null),
        (sets: 1, group: null),
      ]);
      expect(
        s.nextForCompletion(1, 0, done({'0:0'})),
        isNull,
      );
    });

    test('firstIncomplete follows walker order through groups', () {
      final s = seq([
        (sets: 2, group: 1),
        (sets: 2, group: 1),
      ]);
      // Round 0 fully done → first hole is A.set1 (round 1 start).
      expect(
        s.firstIncomplete(done({'0:0', '1:0'})),
        (eIdx: 0, sIdx: 1),
      );
      // B.set0 skipped → walker order puts it before A.set1.
      expect(
        s.firstIncomplete(done({'0:0'})),
        (eIdx: 1, sIdx: 0),
      );
    });
  });
}
