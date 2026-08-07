/// The v14 → v15 rest translation, kept pure so the one-shot data step can be
/// unit-tested. A migration only ever runs once per install and rewrites rows
/// in place, so getting it wrong is not something a later release can repair.
///
/// Before v15 a circuit rested once per round, using its **first** member's
/// `restSeconds`, and that rest fell after the **last** member's set. From v15
/// every set is followed by its own exercise's rest. Preserving how a routine
/// actually ran therefore means moving the round rest from the first member to
/// the last, and zeroing every member before it — zeroing the first member
/// alone (the obvious reading) would drop the round rest instead of moving it.
library;

/// One exercise row, in `(parent, orderIndex)` order.
typedef GroupRestRow = ({
  String syncId,
  String parent,
  int? group,
  int restSeconds,
});

/// The rows whose rest must change, and the parents that contain them.
typedef GroupRestPlan = ({Map<String, int> restBySyncId, Set<String> parents});

/// Computes the translation for [rows], which must already be sorted by parent
/// and then by order index — contiguity is what makes a group a group.
///
/// Only members of a run of two or more sharing a non-null group are touched. A
/// standalone exercise (or a lone member of a group) already rests after its
/// own set, so its value carries over unchanged.
GroupRestPlan translateCircuitRestV15(List<GroupRestRow> rows) {
  final restBySyncId = <String, int>{};
  final parents = <String>{};
  var i = 0;
  while (i < rows.length) {
    final group = rows[i].group;
    if (group == null) {
      i++;
      continue;
    }
    final parent = rows[i].parent;
    var j = i + 1;
    while (j < rows.length &&
        rows[j].parent == parent &&
        rows[j].group == group) {
      j++;
    }
    if (j - i > 1) {
      final roundRest = rows[i].restSeconds;
      var changed = false;
      for (var k = i; k < j - 1; k++) {
        if (rows[k].restSeconds != 0) {
          restBySyncId[rows[k].syncId] = 0;
          changed = true;
        }
      }
      final last = rows[j - 1];
      if (last.restSeconds != roundRest) {
        restBySyncId[last.syncId] = roundRest;
        changed = true;
      }
      if (changed) parents.add(parent);
    }
    i = j;
  }
  return (restBySyncId: restBySyncId, parents: parents);
}
