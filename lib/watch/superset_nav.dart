// Pure navigation logic for the watch run page. Kept in its own file so the
// algorithm can be unit-tested without standing up a widget tree.
//
// Position is `(eIdx, sIdx)` — exercise index and set index within that
// exercise. The walker honours `supersetGroupAt`: a non-null group ID on
// consecutive exercises means alternating sets across the group (set i of
// every group member, then set i+1, …) before moving on to the next
// standalone exercise or group.

class SupersetSeq {
  SupersetSeq({
    required this.exerciseCount,
    required this.setCountAt,
    required this.supersetGroupAt,
  });

  final int exerciseCount;
  final int Function(int eIdx) setCountAt;
  final int? Function(int eIdx) supersetGroupAt;

  /// Returns the position immediately after `(eIdx, sIdx)` in the alternating
  /// sequence, or null if the workout has no more sets.
  ({int eIdx, int sIdx})? nextAfter(int eIdx, int sIdx) {
    final group = _groupBounds(eIdx);
    if (group != null) {
      final maxSets = _maxSetsInGroup(group);
      final pos = _nextInGroup(eIdx, sIdx, group, maxSets);
      if (pos != null) return pos;
      // Group exhausted — fall through to the next exercise/group.
      return _firstAfter(group.last);
    }
    if (sIdx + 1 < setCountAt(eIdx)) {
      return (eIdx: eIdx, sIdx: sIdx + 1);
    }
    return _firstAfter(eIdx);
  }

  /// Returns the position immediately before `(eIdx, sIdx)`, or null if this
  /// is the first set of the workout.
  ({int eIdx, int sIdx})? prevBefore(int eIdx, int sIdx) {
    final group = _groupBounds(eIdx);
    if (group != null) {
      final pos = _prevInGroup(eIdx, sIdx, group);
      if (pos != null) return pos;
      return _lastBefore(group.first);
    }
    if (sIdx > 0) return (eIdx: eIdx, sIdx: sIdx - 1);
    return _lastBefore(eIdx);
  }

  ({int first, int last})? _groupBounds(int eIdx) {
    final group = supersetGroupAt(eIdx);
    if (group == null) return null;
    var first = eIdx;
    while (first > 0 && supersetGroupAt(first - 1) == group) {
      first--;
    }
    var last = eIdx;
    while (last + 1 < exerciseCount && supersetGroupAt(last + 1) == group) {
      last++;
    }
    return (first: first, last: last);
  }

  int _maxSetsInGroup(({int first, int last}) group) {
    var max = 0;
    for (var i = group.first; i <= group.last; i++) {
      final c = setCountAt(i);
      if (c > max) max = c;
    }
    return max;
  }

  ({int eIdx, int sIdx})? _nextInGroup(
    int eIdx,
    int sIdx,
    ({int first, int last}) group,
    int maxSets,
  ) {
    var e = eIdx;
    var s = sIdx;
    while (true) {
      e++;
      if (e > group.last) {
        e = group.first;
        s++;
      }
      if (s >= maxSets) return null;
      if (s < setCountAt(e)) {
        return (eIdx: e, sIdx: s);
      }
      // Skip — this exercise doesn't have set s; continue alternating.
    }
  }

  ({int eIdx, int sIdx})? _prevInGroup(
    int eIdx,
    int sIdx,
    ({int first, int last}) group,
  ) {
    var e = eIdx;
    var s = sIdx;
    while (true) {
      e--;
      if (e < group.first) {
        e = group.last;
        s--;
      }
      if (s < 0) return null;
      if (s < setCountAt(e)) {
        return (eIdx: e, sIdx: s);
      }
    }
  }

  ({int eIdx, int sIdx})? _firstAfter(int eIdx) {
    for (var i = eIdx + 1; i < exerciseCount; i++) {
      if (setCountAt(i) > 0) return (eIdx: i, sIdx: 0);
    }
    return null;
  }

  ({int eIdx, int sIdx})? _lastBefore(int eIdx) {
    for (var i = eIdx - 1; i >= 0; i--) {
      final c = setCountAt(i);
      if (c > 0) return (eIdx: i, sIdx: c - 1);
    }
    return null;
  }
}
