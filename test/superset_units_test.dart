import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/phone/superset_units.dart';

/// A stand-in for a routine/workout exercise: an id plus its superset group.
typedef Ex = (String id, int? group);

List<SupersetUnit<Ex>> units(List<Ex> items) =>
    buildSupersetUnits<Ex>(items, (e) => e.$2);

String _id(Ex e) => e.$1;

void main() {
  group('buildSupersetUnits', () {
    test('ungrouped exercises are all singles', () {
      final u = units([('a', null), ('b', null)]);
      expect(u.length, 2);
      expect(u.every((x) => !x.isGroup), isTrue);
    });

    test('consecutive members of one group collapse into a block', () {
      final u = units([('a', null), ('b', 1), ('c', 1), ('d', null)]);
      expect(u.map((x) => x.members.map(_id).toList()), [
        ['a'],
        ['b', 'c'],
        ['d'],
      ]);
      expect(u[1].isGroup, isTrue);
    });

    test('a lone member of a group is a single, not a one-member block', () {
      // A "superset" of one is not a superset; rendering it as a block would
      // be misleading.
      final u = units([('a', 7)]);
      expect(u.single.isGroup, isFalse);
    });

    test('two runs of the same group number stay separate blocks', () {
      // Grouping is positional: only *adjacent* members form a superset, so a
      // reused group id on either side of another exercise is two blocks.
      final u = units([('a', 1), ('b', 1), ('c', null), ('d', 1), ('e', 1)]);
      expect(u.map((x) => x.members.map(_id).toList()), [
        ['a', 'b'],
        ['c'],
        ['d', 'e'],
      ]);
    });
  });

  group('reorderUnits', () {
    test('moves a superset as one block, keeping members adjacent', () {
      final u = units([('a', null), ('b', 1), ('c', 1), ('d', null)]);
      // Drag the block (index 1) to the front.
      expect(reorderUnits(u, 1, 0, _id), ['b', 'c', 'a', 'd']);
    });

    test('moving down accounts for the dragged item still being in place', () {
      final u = units([('a', null), ('b', null), ('c', null)]);
      expect(reorderUnits(u, 0, 2, _id), ['b', 'a', 'c']);
    });

    test('a block never interleaves with another block', () {
      final u = units([('a', 1), ('b', 1), ('c', 2), ('d', 2)]);
      final out = reorderUnits(u, 1, 0, _id);
      expect(out, ['c', 'd', 'a', 'b']);
      // Both groups remain contiguous — the invariant SupersetSeq relies on.
      expect(out.indexOf('d') - out.indexOf('c'), 1);
      expect(out.indexOf('b') - out.indexOf('a'), 1);
    });
  });

  group('reorderWithinUnit', () {
    test('swaps members inside a block and leaves the rest alone', () {
      final u = units([('a', null), ('b', 1), ('c', 1), ('d', null)]);
      expect(reorderWithinUnit(u, 1, 1, 0, _id), ['a', 'c', 'b', 'd']);
    });

    test('does not move the block itself', () {
      final u = units([('x', 1), ('y', 1), ('z', null)]);
      final out = reorderWithinUnit(u, 0, 0, 2, _id);
      expect(out, ['y', 'x', 'z']);
      expect(out.last, 'z');
    });
  });
}
