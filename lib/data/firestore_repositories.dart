import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import '../sync/sync_codec.dart';
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

Exercise _synthExercise(String syncId, String name, String kind) => Exercise(
  // The routine doc denormalizes only name/kind for its slots; createdAt and
  // version aren't carried (and the routine editor never shows them), so they
  // are synthesized. The canonical exercise lives in the exercises collection.
  syncId: syncId,
  name: name,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  kind: kind,
  version: 1,
);

/// Firestore-backed routine store. A routine is one nested document
/// (`RoutineTemplateDto`: exercises → planned sets / alternatives). Reads map a
/// doc straight to a [FullRoutine]; child mutations (which the interface
/// addresses by the child's own syncId, not the routine's) scan for the owning
/// routine doc, edit its nested tree in place, and bump the routine `version`.
class FirestoreRoutineRepository implements RoutineRepository {
  FirestoreRoutineRepository({required this.uid, FirebaseFirestore? firestore})
    : _fs = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _fs;

  CollectionReference<Map<String, Object?>> get _col =>
      _fs.collection('users').doc(uid).collection('routines');
  CollectionReference<Map<String, Object?>> get _exCol =>
      _fs.collection('users').doc(uid).collection('exercises');

  static List<Map<String, dynamic>> _asMaps(Object? list) => [
    for (final e in (list as List?) ?? const []) Map<String, dynamic>.from(e as Map),
  ];

  Routine _routineRow(RoutineTemplateDto dto) => Routine(
    syncId: dto.syncId,
    name: dto.name,
    createdAt: DateTime.fromMillisecondsSinceEpoch(dto.createdAtMs),
    version: dto.version,
    deletedAt: dto.deletedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(dto.deletedAtMs!),
  );

  FullRoutine _toFullRoutine(RoutineTemplateDto dto) => FullRoutine(
    routine: _routineRow(dto),
    exercises: [
      for (final re in dto.exercises)
        FullRoutineExercise(
          routineExercise: RoutineExercise(
            syncId: re.syncId,
            routineId: dto.syncId,
            exerciseId: re.exerciseSyncId,
            orderIndex: re.orderIndex,
            restSeconds: re.restSeconds,
            supersetGroup: re.supersetGroup,
          ),
          exercise: _synthExercise(
            re.exerciseSyncId,
            re.exerciseName,
            re.exerciseKind,
          ),
          plannedSets: [
            for (final ps in re.plannedSets)
              PlannedSet(
                syncId: ps.syncId,
                routineExerciseId: re.syncId,
                setIndex: ps.setIndex,
                targetReps: ps.targetReps,
                targetWeightKg: ps.targetWeightKg,
                targetSeconds: ps.targetSeconds,
              ),
          ],
          alternatives: [
            for (final alt in re.alternatives)
              RoutineAlternative(
                join: RoutineExerciseAlternative(
                  syncId: alt.syncId,
                  routineExerciseId: re.syncId,
                  exerciseId: alt.exerciseSyncId,
                  orderIndex: alt.orderIndex,
                ),
                exercise: _synthExercise(
                  alt.exerciseSyncId,
                  alt.exerciseName,
                  alt.exerciseKind,
                ),
                plannedSets: [
                  for (final ps in alt.plannedSets)
                    AlternativePlannedSet(
                      syncId: ps.syncId,
                      alternativeId: alt.syncId,
                      setIndex: ps.setIndex,
                      targetReps: ps.targetReps,
                      targetWeightKg: ps.targetWeightKg,
                      targetSeconds: ps.targetSeconds,
                    ),
                ],
              ),
          ],
          muscles: [
            for (final id in re.muscleSyncIds)
              if (_muscleBySyncId[id] != null) _muscleBySyncId[id]!,
          ],
        ),
    ],
  );

  // -- Reads ------------------------------------------------------------

  @override
  Stream<List<RoutineSummary>> watchRoutineSummaries() {
    return _col.snapshots().map((snap) {
      final rows = snap.docs
          .map((d) => RoutineTemplateDto.fromJson(d.data()))
          .where((dto) => dto.deletedAtMs == null)
          .map((dto) => RoutineSummary(
                routine: _routineRow(dto),
                exerciseCount: dto.exercises.length,
              ))
          .toList();
      rows.sort((a, b) => a.routine.createdAt.compareTo(b.routine.createdAt));
      return rows;
    });
  }

  @override
  Stream<FullRoutine?> watchFullRoutine(String routineId) {
    return _col.doc(routineId).snapshots().map((doc) {
      final d = doc.data();
      if (d == null) return null;
      final dto = RoutineTemplateDto.fromJson(d);
      return dto.deletedAtMs == null ? _toFullRoutine(dto) : null;
    });
  }

  @override
  Future<FullRoutine?> loadFullRoutine(String routineId) async {
    final doc = await _col.doc(routineId).get();
    final d = doc.data();
    if (d == null) return null;
    final dto = RoutineTemplateDto.fromJson(d);
    return dto.deletedAtMs == null ? _toFullRoutine(dto) : null;
  }

  // -- Write helpers ----------------------------------------------------

  /// Load one routine doc, apply [mutate] to its data, bump version, write back.
  Future<void> _editRoutine(
    String routineId,
    void Function(Map<String, dynamic> data) mutate,
  ) async {
    final ref = _col.doc(routineId);
    final doc = await ref.get();
    final data = doc.data();
    if (data == null) return;
    final m = Map<String, dynamic>.from(data);
    mutate(m);
    m['version'] = ((m['version'] as num?)?.toInt() ?? 1) + 1;
    await ref.set(m);
  }

  /// Scan for the routine doc whose exercise tree [findAndMutate] recognises
  /// (returns true once it has mutated the target), then write it back with a
  /// bumped version. The interface addresses children by their own syncId, so
  /// this is how a nested-doc layout resolves the owning routine.
  Future<void> _editOwningRoutine(
    bool Function(List<Map<String, dynamic>> exercises) findAndMutate,
  ) async {
    final snap = await _col.get();
    for (final doc in snap.docs) {
      final m = Map<String, dynamic>.from(doc.data());
      final exs = _asMaps(m['exercises']);
      if (findAndMutate(exs)) {
        m['exercises'] = exs;
        m['version'] = ((m['version'] as num?)?.toInt() ?? 1) + 1;
        await doc.reference.set(m);
        return;
      }
    }
  }

  Future<(String name, String kind, List<Object?> muscleSyncIds)> _lookupExercise(
    String exerciseId,
  ) async {
    final d = (await _exCol.doc(exerciseId).get()).data();
    return (
      (d?['name'] as String?) ?? '',
      (d?['kind'] as String?) ?? exerciseKindReps,
      (d?['muscleSyncIds'] as List?)?.cast<Object?>() ?? const [],
    );
  }

  // -- Routine mutations ------------------------------------------------

  @override
  Future<Routine> createRoutine(String name) async {
    final syncId = _uuid.v4();
    final data = <String, Object?>{
      'syncId': syncId,
      'name': name,
      'version': 1,
      'createdAtMs': DateTime.now().millisecondsSinceEpoch,
      'deletedAtMs': null,
      'exercises': <Object?>[],
    };
    await _col.doc(syncId).set(data);
    return _routineRow(RoutineTemplateDto.fromJson(data));
  }

  @override
  Future<void> renameRoutine(String id, String name) =>
      _editRoutine(id, (m) => m['name'] = name);

  /// Soft-delete tombstone: mark deletedAtMs and drop the children (matching
  /// the Drift deleteRoutine), version-bumped so it wins by LWW.
  @override
  Future<void> deleteRoutine(String id) => _editRoutine(id, (m) {
    m['deletedAtMs'] = DateTime.now().millisecondsSinceEpoch;
    m['exercises'] = <Object?>[];
  });

  // -- Routine-exercise mutations ---------------------------------------

  @override
  Future<RoutineExercise> addExerciseToRoutine({
    required String routineId,
    required String exerciseId,
  }) async {
    final (name, kind, muscleSyncIds) = await _lookupExercise(exerciseId);
    final reId = _uuid.v4();
    var order = 0;
    await _editRoutine(routineId, (m) {
      final exs = _asMaps(m['exercises']);
      order = exs.isEmpty
          ? 0
          : exs
                  .map((e) => (e['orderIndex'] as num).toInt())
                  .reduce((a, b) => a > b ? a : b) +
              1;
      exs.add({
        'syncId': reId,
        'exerciseSyncId': exerciseId,
        'exerciseName': name,
        'exerciseKind': kind,
        'orderIndex': order,
        'restSeconds': 90,
        'supersetGroup': null,
        'plannedSets': <Object?>[],
        'alternatives': <Object?>[],
        'muscleSyncIds': muscleSyncIds,
      });
      m['exercises'] = exs;
    });
    return RoutineExercise(
      syncId: reId,
      routineId: routineId,
      exerciseId: exerciseId,
      orderIndex: order,
      restSeconds: 90,
    );
  }

  @override
  Future<void> removeRoutineExercise(String routineExerciseId) =>
      _editOwningRoutine((exs) {
        final before = exs.length;
        exs.removeWhere((e) => e['syncId'] == routineExerciseId);
        return exs.length != before;
      });

  @override
  Future<void> reorderRoutineExercises({
    required String routineId,
    required List<String> orderedIds,
  }) => _editRoutine(routineId, (m) {
    final exs = _asMaps(m['exercises']);
    final bySync = {for (final e in exs) e['syncId'] as String: e};
    final reordered = <Map<String, dynamic>>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final e = bySync[orderedIds[i]];
      if (e != null) {
        e['orderIndex'] = i;
        reordered.add(e);
      }
    }
    // Keep any not named in orderedIds (defensive), after the ordered ones.
    for (final e in exs) {
      if (!orderedIds.contains(e['syncId'])) reordered.add(e);
    }
    m['exercises'] = reordered;
  });

  @override
  Future<void> setRestSeconds(String routineExerciseId, int seconds) =>
      _editOwningRoutine((exs) {
        for (final e in exs) {
          if (e['syncId'] == routineExerciseId) {
            e['restSeconds'] = seconds;
            return true;
          }
        }
        return false;
      });

  @override
  Future<void> setSupersetGroup(String routineExerciseId, int? group) =>
      _editOwningRoutine((exs) {
        for (final e in exs) {
          if (e['syncId'] == routineExerciseId) {
            e['supersetGroup'] = group;
            return true;
          }
        }
        return false;
      });

  // -- Planned-set mutations --------------------------------------------

  @override
  Future<PlannedSet> addPlannedSet({
    required String routineExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    final psId = _uuid.v4();
    var setIndex = 0;
    await _editOwningRoutine((exs) {
      for (final e in exs) {
        if (e['syncId'] == routineExerciseId) {
          final ps = _asMaps(e['plannedSets']);
          setIndex = ps.length;
          ps.add({
            'syncId': psId,
            'setIndex': setIndex,
            'targetReps': targetReps,
            'targetWeightKg': targetWeightKg,
            'targetSeconds': targetSeconds,
          });
          e['plannedSets'] = ps;
          return true;
        }
      }
      return false;
    });
    return PlannedSet(
      syncId: psId,
      routineExerciseId: routineExerciseId,
      setIndex: setIndex,
      targetReps: targetReps,
      targetWeightKg: targetWeightKg,
      targetSeconds: targetSeconds,
    );
  }

  @override
  Future<void> updatePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) => _editOwningRoutine((exs) {
    for (final e in exs) {
      final ps = _asMaps(e['plannedSets']);
      for (final s in ps) {
        if (s['syncId'] == id) {
          s['targetReps'] = targetReps;
          s['targetWeightKg'] = targetWeightKg;
          s['targetSeconds'] = targetSeconds;
          e['plannedSets'] = ps;
          return true;
        }
      }
    }
    return false;
  });

  @override
  Future<void> deletePlannedSet(String id) => _editOwningRoutine((exs) {
    for (final e in exs) {
      final ps = _asMaps(e['plannedSets']);
      final before = ps.length;
      ps.removeWhere((s) => s['syncId'] == id);
      if (ps.length != before) {
        e['plannedSets'] = ps;
        return true;
      }
    }
    return false;
  });

  // -- Alternative mutations --------------------------------------------

  @override
  Future<RoutineExerciseAlternative> addRoutineExerciseAlternative({
    required String routineExerciseId,
    required String exerciseId,
  }) async {
    final (name, kind, _) = await _lookupExercise(exerciseId);
    final altId = _uuid.v4();
    var order = 0;
    await _editOwningRoutine((exs) {
      for (final e in exs) {
        if (e['syncId'] == routineExerciseId) {
          final alts = _asMaps(e['alternatives']);
          order = alts.length;
          alts.add({
            'syncId': altId,
            'exerciseSyncId': exerciseId,
            'exerciseName': name,
            'exerciseKind': kind,
            'orderIndex': order,
            'plannedSets': <Object?>[],
          });
          e['alternatives'] = alts;
          return true;
        }
      }
      return false;
    });
    return RoutineExerciseAlternative(
      syncId: altId,
      routineExerciseId: routineExerciseId,
      exerciseId: exerciseId,
      orderIndex: order,
    );
  }

  @override
  Future<AlternativePlannedSet> addAlternativePlannedSet({
    required String alternativeId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    final psId = _uuid.v4();
    var setIndex = 0;
    await _editOwningRoutine((exs) {
      for (final e in exs) {
        final alts = _asMaps(e['alternatives']);
        for (final a in alts) {
          if (a['syncId'] == alternativeId) {
            final ps = _asMaps(a['plannedSets']);
            setIndex = ps.length;
            ps.add({
              'syncId': psId,
              'setIndex': setIndex,
              'targetReps': targetReps,
              'targetWeightKg': targetWeightKg,
              'targetSeconds': targetSeconds,
            });
            a['plannedSets'] = ps;
            e['alternatives'] = alts;
            return true;
          }
        }
      }
      return false;
    });
    return AlternativePlannedSet(
      syncId: psId,
      alternativeId: alternativeId,
      setIndex: setIndex,
      targetReps: targetReps,
      targetWeightKg: targetWeightKg,
      targetSeconds: targetSeconds,
    );
  }

  @override
  Future<void> updateAlternativePlannedSet({
    required String id,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) => _editOwningRoutine((exs) {
    for (final e in exs) {
      final alts = _asMaps(e['alternatives']);
      for (final a in alts) {
        final ps = _asMaps(a['plannedSets']);
        for (final s in ps) {
          if (s['syncId'] == id) {
            s['targetReps'] = targetReps;
            s['targetWeightKg'] = targetWeightKg;
            s['targetSeconds'] = targetSeconds;
            a['plannedSets'] = ps;
            e['alternatives'] = alts;
            return true;
          }
        }
      }
    }
    return false;
  });

  @override
  Future<void> deleteAlternativePlannedSet(String id) =>
      _editOwningRoutine((exs) {
        for (final e in exs) {
          final alts = _asMaps(e['alternatives']);
          for (final a in alts) {
            final ps = _asMaps(a['plannedSets']);
            final before = ps.length;
            ps.removeWhere((s) => s['syncId'] == id);
            if (ps.length != before) {
              a['plannedSets'] = ps;
              e['alternatives'] = alts;
              return true;
            }
          }
        }
        return false;
      });

  @override
  Future<void> removeRoutineExerciseAlternative(String alternativeId) =>
      _editOwningRoutine((exs) {
        for (final e in exs) {
          final alts = _asMaps(e['alternatives']);
          final before = alts.length;
          alts.removeWhere((a) => a['syncId'] == alternativeId);
          if (alts.length != before) {
            e['alternatives'] = alts;
            return true;
          }
        }
        return false;
      });
}
