/// Grouping and reordering for lists where consecutive items sharing a
/// non-null circuit group form one block.
///
/// Circuits are encoded positionally: `RoutineExercises.circuitGroup` /
/// `WorkoutExercises.circuitGroup` mean "a circuit" only while the members
/// stay *adjacent* (see `lib/watch/circuit_nav.dart`, which walks them in that
/// order). A flat drag-and-drop can interleave two groups and silently change
/// what the list means, so reordering works on units — a circuit moves as one
/// block, and members reorder only within their own block.
///
/// Deliberately generic and free of Flutter and Drift, so both the routine and
/// workout editors can share it and it can be tested in isolation.
library;

class CircuitUnit<T> {
  CircuitUnit(this.members);

  final List<T> members;

  bool get isGroup => members.length > 1;
  T get first => members.first;
}

/// Collapse [items] into units: runs of consecutive items sharing the same
/// non-null group become one unit, everything else stands alone.
///
/// A run of length one is a single, not a group — a "circuit" with one member
/// is not a circuit, and rendering it as a block would be misleading.
List<CircuitUnit<T>> buildCircuitUnits<T>(
  List<T> items,
  int? Function(T) groupOf,
) {
  final units = <CircuitUnit<T>>[];
  var i = 0;
  while (i < items.length) {
    final g = groupOf(items[i]);
    if (g == null) {
      units.add(CircuitUnit([items[i]]));
      i++;
      continue;
    }
    var j = i + 1;
    while (j < items.length && groupOf(items[j]) == g) {
      j++;
    }
    units.add(CircuitUnit(items.sublist(i, j)));
    i = j;
  }
  return units;
}

/// Move the unit at [oldIndex] to [newIndex] and flatten back to a flat id
/// list, ready for `reorder*Exercises(orderedIds: …)`.
///
/// [newIndex] follows Flutter's [ReorderableListView] convention, where an
/// index past the original position counts the item still being in place.
List<String> reorderUnits<T>(
  List<CircuitUnit<T>> units,
  int oldIndex,
  int newIndex,
  String Function(T) idOf,
) {
  final list = List<CircuitUnit<T>>.from(units);
  var insertAt = newIndex;
  if (newIndex > oldIndex) insertAt -= 1;
  final moved = list.removeAt(oldIndex);
  list.insert(insertAt, moved);
  return [
    for (final u in list)
      for (final m in u.members) idOf(m),
  ];
}

/// Move a member within the unit at [unitIndex], leaving every other unit and
/// the units' order untouched. Keeps the group contiguous by construction.
List<String> reorderWithinUnit<T>(
  List<CircuitUnit<T>> units,
  int unitIndex,
  int oldIndex,
  int newIndex,
  String Function(T) idOf,
) {
  final members = List<T>.from(units[unitIndex].members);
  var insertAt = newIndex;
  if (newIndex > oldIndex) insertAt -= 1;
  final moved = members.removeAt(oldIndex);
  members.insert(insertAt, moved);
  return [
    for (var u = 0; u < units.length; u++)
      for (final m in u == unitIndex ? members : units[u].members) idOf(m),
  ];
}
