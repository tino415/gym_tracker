import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';
import 'muscle_seeds.dart';
import 'repositories.dart';

const _uuid = Uuid();

/// Firestore-backed implementations of the repository interfaces, used by the
/// web build. Each entity is one document keyed by its `syncId` under
/// `users/{uid}/...`, holding the same DTO JSON that flows over sync — so the
/// UUID identity means a doc maps straight to a Drift row with no id synthesis.
///
/// Writes are version-LWW aware (bump `version` on every edit, soft-delete via
/// `deletedAtMs`) so they interoperate with the phone/watch sync apply path,
/// which arbitrates the same docs by version.

/// Static muscle registry (see muscle_seeds.dart): muscles are deterministic
/// reference data, not stored in Firestore. Keyed by their derived syncId.
final Map<String, Muscle> _muscleBySyncId = {
  for (final name in muscleSeeds)
    muscleSyncId(name): Muscle(syncId: muscleSyncId(name), name: name),
};

Exercise _exerciseFromData(Map<String, Object?> d) => Exercise(
  syncId: d['syncId'] as String,
  name: d['name'] as String,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    (d['createdAtMs'] as num).toInt(),
  ),
  kind: (d['kind'] as String?) ?? exerciseKindReps,
  version: (d['version'] as num?)?.toInt() ?? 1,
  deletedAt: d['deletedAtMs'] == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch((d['deletedAtMs'] as num).toInt()),
);

List<Muscle> _musclesFor(Map<String, Object?> d) {
  final ids = (d['muscleSyncIds'] as List?)?.cast<Object?>() ?? const [];
  return [
    for (final id in ids)
      if (_muscleBySyncId[id as String] != null) _muscleBySyncId[id]!,
  ];
}

class FirestoreExerciseRepository implements ExerciseRepository {
  FirestoreExerciseRepository({required this.uid, FirebaseFirestore? firestore})
    : _fs = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _fs;

  CollectionReference<Map<String, Object?>> get _col =>
      _fs.collection('users').doc(uid).collection('exercises');

  // -- Reads ------------------------------------------------------------

  @override
  Stream<List<Exercise>> watchExercises() {
    return _col.snapshots().map((snap) {
      final rows = snap.docs
          .map((d) => d.data())
          .where((d) => d['deletedAtMs'] == null) // hide tombstones
          .map(_exerciseFromData)
          .toList();
      rows.sort((a, b) => a.name.compareTo(b.name));
      return rows;
    });
  }

  @override
  Stream<List<ExerciseWithMuscles>> watchExercisesWithMuscles() {
    return _col.snapshots().map((snap) {
      final rows = snap.docs
          .map((d) => d.data())
          .where((d) => d['deletedAtMs'] == null)
          .map((d) => ExerciseWithMuscles(
                exercise: _exerciseFromData(d),
                muscles: _musclesFor(d),
              ))
          .toList();
      rows.sort((a, b) => a.exercise.name.compareTo(b.exercise.name));
      return rows;
    });
  }

  @override
  Stream<List<Muscle>> watchMuscles() {
    // Static reference data — no Firestore round-trip.
    final all = [
      for (final name in muscleSeeds) Muscle(syncId: muscleSyncId(name), name: name),
    ];
    return Stream.value(all);
  }

  @override
  Future<List<Muscle>> musclesForExercise(String exerciseId) async {
    final doc = await _col.doc(exerciseId).get();
    final d = doc.data();
    return d == null ? const [] : _musclesFor(d);
  }

  // -- Mutations (version-LWW aware) ------------------------------------

  @override
  Future<Exercise> createExercise(
    String name, {
    String kind = exerciseKindReps,
  }) async {
    final syncId = _uuid.v4();
    final data = <String, Object?>{
      'syncId': syncId,
      'name': name,
      'kind': kind,
      'version': 1,
      'createdAtMs': DateTime.now().millisecondsSinceEpoch,
      'muscleSyncIds': <String>[],
      'deletedAtMs': null,
    };
    await _col.doc(syncId).set(data);
    return _exerciseFromData(data);
  }

  @override
  Future<void> renameExercise(String id, String name) => _col.doc(id).update({
    'name': name,
    'version': FieldValue.increment(1),
  });

  @override
  Future<void> setExerciseKind(String id, String kind) => _col.doc(id).update({
    'kind': kind,
    'version': FieldValue.increment(1),
  });

  @override
  Future<void> setExerciseMuscles(String exerciseId, List<String> muscleIds) =>
      _col.doc(exerciseId).update({
        'muscleSyncIds': muscleIds,
        'version': FieldValue.increment(1),
      });

  /// Soft delete: tombstone via `deletedAtMs` + version bump, matching the
  /// Drift/​sync semantics so the deletion propagates by version-LWW.
  @override
  Future<void> deleteExercise(String id) => _col.doc(id).update({
    'deletedAtMs': DateTime.now().millisecondsSinceEpoch,
    'version': FieldValue.increment(1),
  });
}
