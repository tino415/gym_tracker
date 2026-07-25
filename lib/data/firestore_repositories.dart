import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' show Value;
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

/// Firestore-backed workout store. A workout is one document (`WorkoutDto`:
/// exercises → sets, plus a workout-level completions list keyed by
/// workoutSetSyncId). Reads map a doc to a [FullWorkout] (completions attached
/// per set); edits touch the nested doc. Workouts have no version field — the
/// web is the only editor of a given workout, and cross-device edit propagation
/// is the separate "versioned workouts" task.
class FirestoreWorkoutRepository implements WorkoutRepository {
  FirestoreWorkoutRepository({required this.uid, FirebaseFirestore? firestore})
    : _fs = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _fs;

  CollectionReference<Map<String, Object?>> get _col =>
      _fs.collection('users').doc(uid).collection('workouts');
  CollectionReference<Map<String, Object?>> get _exCol =>
      _fs.collection('users').doc(uid).collection('exercises');

  static List<Map<String, dynamic>> _asMaps(Object? list) => [
    for (final e in (list as List?) ?? const []) Map<String, dynamic>.from(e as Map),
  ];

  Workout _workoutRow(WorkoutDto dto) => Workout(
    syncId: dto.syncId,
    routineId: dto.routineSyncId,
    startedAt: DateTime.fromMillisecondsSinceEpoch(dto.startedAtMs),
    endedAt: dto.endedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(dto.endedAtMs!),
    avgHeartRate: dto.avgHeartRate,
    maxHeartRate: dto.maxHeartRate,
  );

  SetCompletion _completionRow(SetCompletionDto c, String workoutId) =>
      SetCompletion(
        syncId: c.syncId,
        workoutId: workoutId,
        workoutSetId: c.workoutSetSyncId,
        actualReps: c.actualReps,
        actualWeightKg: c.actualWeightKg,
        actualSeconds: c.actualSeconds,
        completedAt: DateTime.fromMillisecondsSinceEpoch(c.completedAtMs),
        avgHeartRate: c.avgHeartRate,
        maxHeartRate: c.maxHeartRate,
      );

  FullWorkout _toFullWorkout(WorkoutDto dto) {
    final completionBySet = {
      for (final c in dto.completions) c.workoutSetSyncId: c,
    };
    return FullWorkout(
      workout: _workoutRow(dto),
      // The workout snapshot is self-contained (names live on it); the source
      // routine link isn't needed to render history.
      routine: null,
      exercises: [
        for (final we in dto.exercises)
          FullWorkoutExercise(
            workoutExercise: WorkoutExercise(
              syncId: we.syncId,
              workoutId: dto.syncId,
              exerciseId: we.exerciseSyncId,
              exerciseName: we.exerciseName,
              orderIndex: we.orderIndex,
              restSeconds: we.restSeconds,
              supersetGroup: we.supersetGroup,
              kind: we.kind,
              routineExerciseId: we.routineExerciseSyncId,
            ),
            sets: [
              for (final ws in we.sets)
                FullWorkoutSet(
                  workoutSet: WorkoutSet(
                    syncId: ws.syncId,
                    workoutExerciseId: we.syncId,
                    setIndex: ws.setIndex,
                    targetReps: ws.targetReps,
                    targetWeightKg: ws.targetWeightKg,
                    targetSeconds: ws.targetSeconds,
                  ),
                  completion: completionBySet[ws.syncId] == null
                      ? null
                      : _completionRow(completionBySet[ws.syncId]!, dto.syncId),
                ),
            ],
          ),
      ],
    );
  }

  // -- Reads ------------------------------------------------------------

  @override
  Stream<List<Workout>> watchRecentWorkouts() {
    return _col.snapshots().map((snap) {
      final rows = snap.docs
          .map((d) => _workoutRow(WorkoutDto.fromJson(d.data())))
          .toList();
      rows.sort((a, b) => b.startedAt.compareTo(a.startedAt)); // newest first
      return rows;
    });
  }

  @override
  Stream<Workout?> watchInProgressWorkout() {
    return _col.snapshots().map((snap) {
      final open = snap.docs
          .map((d) => WorkoutDto.fromJson(d.data()))
          .where((dto) => dto.endedAtMs == null)
          .map(_workoutRow)
          .toList();
      open.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return open.isEmpty ? null : open.first;
    });
  }

  @override
  Stream<FullWorkout?> watchFullWorkout(String workoutId) {
    return _col.doc(workoutId).snapshots().map((doc) {
      final d = doc.data();
      return d == null ? null : _toFullWorkout(WorkoutDto.fromJson(d));
    });
  }

  // -- Improvements (cross-collection analytics) ------------------------
  // Deferred on the Firestore backend: it compares a workout's completions
  // against its source routine's planned targets. Tracked as a follow-up; the
  // web history page just shows no suggestions until then.
  @override
  Future<List<WorkoutImprovement>> findWorkoutImprovements(String workoutId) async =>
      const [];

  @override
  Future<void> applyWorkoutImprovements(String workoutId) async {}

  // -- Write helpers ----------------------------------------------------

  Future<void> _editWorkout(
    String workoutId,
    void Function(Map<String, dynamic> data) mutate,
  ) async {
    final ref = _col.doc(workoutId);
    final doc = await ref.get();
    final data = doc.data();
    if (data == null) return;
    final m = Map<String, dynamic>.from(data);
    mutate(m);
    await ref.set(m);
  }

  Future<void> _editOwningWorkout(
    bool Function(Map<String, dynamic> data) findAndMutate,
  ) async {
    final snap = await _col.get();
    for (final doc in snap.docs) {
      final m = Map<String, dynamic>.from(doc.data());
      if (findAndMutate(m)) {
        await doc.reference.set(m);
        return;
      }
    }
  }

  // -- Workout-level mutations ------------------------------------------

  @override
  Future<void> updateWorkoutTimes({
    required String workoutId,
    required DateTime startedAt,
    required DateTime? endedAt,
  }) => _editWorkout(workoutId, (m) {
    m['startedAtMs'] = startedAt.millisecondsSinceEpoch;
    m['endedAtMs'] = endedAt?.millisecondsSinceEpoch;
  });

  @override
  Future<void> deleteWorkout(String workoutId) => _col.doc(workoutId).delete();

  @override
  Future<WorkoutExercise> addWorkoutExercise({
    required String workoutId,
    required String exerciseId,
  }) async {
    final exDoc = await _exCol.doc(exerciseId).get();
    final name = (exDoc.data()?['name'] as String?) ?? '';
    final kind = (exDoc.data()?['kind'] as String?) ?? exerciseKindReps;
    final weId = _uuid.v4();
    var order = 0;
    await _editWorkout(workoutId, (m) {
      final exs = _asMaps(m['exercises']);
      order = exs.isEmpty
          ? 0
          : exs
                  .map((e) => (e['orderIndex'] as num).toInt())
                  .reduce((a, b) => a > b ? a : b) +
              1;
      exs.add({
        'syncId': weId,
        'exerciseSyncId': exerciseId,
        'exerciseName': name,
        'kind': kind,
        'orderIndex': order,
        'restSeconds': 90,
        'supersetGroup': null,
        'sets': <Object?>[],
        'routineExerciseSyncId': null,
      });
      m['exercises'] = exs;
    });
    return WorkoutExercise(
      syncId: weId,
      workoutId: workoutId,
      exerciseId: exerciseId,
      exerciseName: name,
      orderIndex: order,
      restSeconds: 90,
      kind: kind,
    );
  }

  @override
  Future<void> removeWorkoutExercise(String workoutExerciseId) =>
      _editOwningWorkout((m) {
        final exs = _asMaps(m['exercises']);
        final target = exs.where((e) => e['syncId'] == workoutExerciseId).toList();
        if (target.isEmpty) return false;
        // Drop the exercise and any completions bound to its sets.
        final setIds = {
          for (final s in _asMaps(target.first['sets'])) s['syncId'] as String,
        };
        exs.removeWhere((e) => e['syncId'] == workoutExerciseId);
        m['exercises'] = exs;
        final comps = _asMaps(m['completions'])
          ..removeWhere((c) => setIds.contains(c['workoutSetSyncId']));
        m['completions'] = comps;
        return true;
      });

  @override
  Future<WorkoutSet> addWorkoutSet({
    required String workoutExerciseId,
    int? targetReps,
    double? targetWeightKg,
    int? targetSeconds,
  }) async {
    final wsId = _uuid.v4();
    var setIndex = 0;
    await _editOwningWorkout((m) {
      final exs = _asMaps(m['exercises']);
      for (final e in exs) {
        if (e['syncId'] == workoutExerciseId) {
          final sets = _asMaps(e['sets']);
          setIndex = sets.length;
          sets.add({
            'syncId': wsId,
            'setIndex': setIndex,
            'targetReps': targetReps,
            'targetWeightKg': targetWeightKg,
            'targetSeconds': targetSeconds,
          });
          e['sets'] = sets;
          m['exercises'] = exs;
          return true;
        }
      }
      return false;
    });
    return WorkoutSet(
      syncId: wsId,
      workoutExerciseId: workoutExerciseId,
      setIndex: setIndex,
      targetReps: targetReps,
      targetWeightKg: targetWeightKg,
      targetSeconds: targetSeconds,
    );
  }

  @override
  Future<void> removeWorkoutSet(String workoutSetId) => _editOwningWorkout((m) {
    final exs = _asMaps(m['exercises']);
    var found = false;
    for (final e in exs) {
      final sets = _asMaps(e['sets']);
      final before = sets.length;
      sets.removeWhere((s) => s['syncId'] == workoutSetId);
      if (sets.length != before) {
        e['sets'] = sets;
        found = true;
        break;
      }
    }
    if (!found) return false;
    m['exercises'] = exs;
    final comps = _asMaps(m['completions'])
      ..removeWhere((c) => c['workoutSetSyncId'] == workoutSetId);
    m['completions'] = comps;
    return true;
  });

  // -- Completion mutations ---------------------------------------------

  @override
  Future<SetCompletion> upsertSetCompletion({
    required String workoutId,
    required String workoutSetId,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    Value<int?> avgHeartRate = const Value.absent(),
    Value<int?> maxHeartRate = const Value.absent(),
  }) async {
    late SetCompletion result;
    await _editWorkout(workoutId, (m) {
      final comps = _asMaps(m['completions']);
      final existing = comps.where((c) => c['workoutSetSyncId'] == workoutSetId);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      Map<String, dynamic> row;
      if (existing.isNotEmpty) {
        row = existing.first;
        row['actualReps'] = actualReps;
        row['actualWeightKg'] = actualWeightKg;
        row['actualSeconds'] = actualSeconds;
        row['completedAtMs'] = nowMs;
        if (avgHeartRate.present) row['avgHeartRate'] = avgHeartRate.value;
        if (maxHeartRate.present) row['maxHeartRate'] = maxHeartRate.value;
      } else {
        row = {
          'syncId': _uuid.v4(),
          'workoutSetSyncId': workoutSetId,
          'actualReps': actualReps,
          'actualWeightKg': actualWeightKg,
          'actualSeconds': actualSeconds,
          'completedAtMs': nowMs,
          'avgHeartRate': avgHeartRate.present ? avgHeartRate.value : null,
          'maxHeartRate': maxHeartRate.present ? maxHeartRate.value : null,
        };
        comps.add(row);
      }
      m['completions'] = comps;
      result = _completionRow(
        SetCompletionDto.fromJson(Map<String, Object?>.from(row)),
        workoutId,
      );
    });
    return result;
  }

  @override
  Future<void> updateCompletion({
    required String id,
    int? actualReps,
    double? actualWeightKg,
    int? actualSeconds,
    DateTime? completedAt,
  }) => _editOwningWorkout((m) {
    final comps = _asMaps(m['completions']);
    for (final c in comps) {
      if (c['syncId'] == id) {
        c['actualReps'] = actualReps;
        c['actualWeightKg'] = actualWeightKg;
        c['actualSeconds'] = actualSeconds;
        if (completedAt != null) {
          c['completedAtMs'] = completedAt.millisecondsSinceEpoch;
        }
        m['completions'] = comps;
        return true;
      }
    }
    return false;
  });

  @override
  Future<void> deleteCompletion(String id) => _editOwningWorkout((m) {
    final comps = _asMaps(m['completions']);
    final before = comps.length;
    comps.removeWhere((c) => c['syncId'] == id);
    if (comps.length == before) return false;
    m['completions'] = comps;
    return true;
  });
}
