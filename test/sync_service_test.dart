import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/sync/sync_codec.dart';
import 'package:gym_tracker/sync/sync_repository.dart';
import 'package:gym_tracker/sync/sync_service.dart';
import 'package:gym_tracker/sync/sync_transport.dart';

/// In-memory transport that records outbound messages and lets a test inject
/// inbound ones. Two of these can be cross-wired to simulate a phone/watch
/// pair without any platform channel.
class FakeTransport implements SyncTransport {
  final _inbound = StreamController<SyncMessage>.broadcast();
  final List<SyncMessage> sent = [];
  bool started = false;
  bool disposed = false;

  @override
  Stream<SyncMessage> get messages => _inbound.stream;

  @override
  Future<void> send({
    required String type,
    required Map<String, Object?> payload,
  }) async {
    sent.add(SyncMessage(type: type, payload: payload));
  }

  /// Push an inbound message as if it arrived from the peer.
  void deliver(SyncMessage msg) => _inbound.add(msg);

  @override
  void start() => started = true;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _inbound.close();
  }
}

Future<String> _seedRoutine(AppDatabase db, {String name = 'Push day'}) async {
  await db
      .into(db.routines)
      .insert(
        RoutinesCompanion.insert(
          syncId: 'routine-1',
          name: name,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
  await db
      .into(db.exercises)
      .insert(
        ExercisesCompanion.insert(
          syncId: 'ex-1',
          name: 'Bench Press',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
  await db
      .into(db.routineExercises)
      .insert(
        RoutineExercisesCompanion.insert(
          syncId: 're-1',
          routineId: 'routine-1',
          exerciseId: 'ex-1',
          orderIndex: 0,
        ),
      );
  await db
      .into(db.plannedSets)
      .insert(
        PlannedSetsCompanion.insert(
          syncId: 'ps-1',
          routineExerciseId: 're-1',
          setIndex: 0,
          targetReps: const Value(10),
          targetWeightKg: const Value(50),
        ),
      );
  return 'routine-1';
}

void main() {
  late AppDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  SyncService serviceWith(
    List<SyncTransport> transports, {
    required bool isRoutineAuthority,
    void Function(String)? onWorkoutApplied,
  }) {
    return SyncService(
      db,
      repo,
      isRoutineAuthority: isRoutineAuthority,
      transports: transports,
      onWorkoutApplied: onWorkoutApplied,
    );
  }

  test('authority pushes its routine bundle on start to every transport',
      () async {
    await _seedRoutine(db);
    final a = FakeTransport();
    final b = FakeTransport();
    final svc = serviceWith([a, b], isRoutineAuthority: true);
    svc.start();

    // The initial context push is debounced 500ms; the request-for-peer-state
    // goes out immediately.
    await Future<void>.delayed(const Duration(milliseconds: 700));

    for (final t in [a, b]) {
      expect(t.started, isTrue);
      expect(
        t.sent.where((m) => m.type == routineBundleType),
        isNotEmpty,
        reason: 'each transport receives the routine bundle',
      );
      expect(
        t.sent.where((m) => m.type == syncRequestType),
        isNotEmpty,
        reason: 'each transport is asked for peer state',
      );
    }
    await svc.dispose();
  });

  test('a non-authority (watch) never pushes routine bundles', () async {
    await _seedRoutine(db);
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: false);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(t.sent.where((m) => m.type == routineBundleType), isEmpty);
    await svc.dispose();
  });

  test('authority pushes its exercise-library bundle on start', () async {
    await db.createExercise('Bench Press');
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final bundles = t.sent.where((m) => m.type == exerciseBundleType).toList();
    expect(bundles, isNotEmpty, reason: 'exercise library rides alongside routines');
    final decoded = ExerciseBundleMessage.fromPayload(bundles.last.payload);
    expect(decoded.exercises.any((e) => e.name == 'Bench Press'), isTrue);
    await svc.dispose();
  });

  test('a non-authority (watch) never pushes exercise bundles', () async {
    await db.createExercise('Bench Press');
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: false);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(t.sent.where((m) => m.type == exerciseBundleType), isEmpty);
    await svc.dispose();
  });

  test('inbound exercise bundle from a transport is applied to the db',
      () async {
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: false);
    svc.start();

    t.deliver(
      SyncMessage(
        type: exerciseBundleType,
        payload: ExerciseBundleMessage([
          ExerciseDto(
            syncId: 'ex-remote',
            name: 'Remote Curl',
            kind: exerciseKindReps,
            version: 1,
            createdAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
          ),
        ]).toPayload(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final rows = await (db.select(db.exercises)
          ..where((t) => t.syncId.equals('ex-remote')))
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.name, 'Remote Curl');
    await svc.dispose();
  });

  test('inbound routine bundle from a transport is applied to the db',
      () async {
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: false);
    svc.start();

    final bundle = RoutineBundleMessage([
      RoutineTemplateDto(
        syncId: 'routine-9',
        name: 'Pull day',
        version: 1,
        createdAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        exercises: const [],
      ),
    ]);
    t.deliver(SyncMessage(type: routineBundleType, payload: bundle.toPayload()));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final routines = await db.select(db.routines).get();
    expect(routines.map((r) => r.syncId), contains('routine-9'));
    await svc.dispose();
  });

  test('inbound routine upsert is non-destructive — keeps other routines',
      () async {
    // Seed a local routine, then receive an upsert for a *different* routine.
    // The authoritative bundle path would delete the seeded one; the upsert
    // path must not.
    await _seedRoutine(db);
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();

    final upsert = RoutineBundleMessage([
      RoutineTemplateDto(
        syncId: 'routine-2',
        name: 'Leg day',
        version: 1,
        createdAtMs: DateTime.utc(2026, 1, 2).millisecondsSinceEpoch,
        exercises: const [],
      ),
    ]);
    t.deliver(SyncMessage(type: routineUpsertType, payload: upsert.toPayload()));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final routines = await db.select(db.routines).get();
    expect(
      routines.map((r) => r.syncId),
      containsAll(<String>['routine-1', 'routine-2']),
    );
    await svc.dispose();
  });

  test('inbound routine-deleted removes the named routine only', () async {
    await _seedRoutine(db); // routine-1
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();

    t.deliver(
      SyncMessage(
        type: routineDeletedType,
        payload: const RoutineDeletedMessage(['routine-1']).toPayload(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final routines = await db.select(db.routines).get();
    expect(routines, isEmpty);
    await svc.dispose();
  });

  test('a watch-completed workout is applied and relayed to the other transport',
      () async {
    final wear = FakeTransport();
    final server = FakeTransport();
    final svc = serviceWith([wear, server], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    wear.sent.clear();
    server.sent.clear();

    final dto = WorkoutDto(
      syncId: 'w-1',
      routineSyncId: null,
      startedAtMs: DateTime.utc(2026, 1, 2).millisecondsSinceEpoch,
      endedAtMs: DateTime.utc(2026, 1, 2, 1).millisecondsSinceEpoch,
      exercises: const [],
      completions: const [],
    );
    // Arrives over the Wear bridge, as if finished on the watch.
    wear.deliver(
      SyncMessage(
        type: workoutCompletedType,
        payload: WorkoutCompletedMessage(dto).toPayload(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Applied locally...
    final workouts = await db.select(db.workouts).get();
    expect(workouts.where((w) => w.syncId == 'w-1'), hasLength(1));
    // ...relayed to the server, but never echoed back to its source (wear).
    final relayed =
        server.sent.where((m) => m.type == workoutCompletedType).toList();
    expect(relayed, hasLength(1));
    expect(relayed.first.payload['syncId'], 'w-1');
    expect(wear.sent.where((m) => m.type == workoutCompletedType), isEmpty);
    await svc.dispose();
  });

  group('onWorkoutApplied (Health Connect publishing)', () {
    WorkoutDto dtoFor(String id, {int version = 1}) => WorkoutDto(
      syncId: id,
      routineSyncId: null,
      startedAtMs: DateTime.utc(2026, 1, 2).millisecondsSinceEpoch,
      endedAtMs: DateTime.utc(2026, 1, 2, 1).millisecondsSinceEpoch,
      exercises: const [],
      completions: const [],
      version: version,
    );

    test('fires for a workout that arrives from the watch', () async {
      // The point of the hook: workouts run on the watch are the ones carrying
      // heart rate, and the watch has no health store to write them to.
      final applied = <String>[];
      final wear = FakeTransport();
      final svc = serviceWith(
        [wear],
        isRoutineAuthority: true,
        onWorkoutApplied: applied.add,
      );
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      wear.deliver(
        SyncMessage(
          type: workoutCompletedType,
          payload: WorkoutCompletedMessage(dtoFor('w-hc')).toPayload(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(applied, ['w-hc']);
      await svc.dispose();
    });

    test('does not fire when the inbound copy is rejected', () async {
      final applied = <String>[];
      final wear = FakeTransport();
      final svc = serviceWith(
        [wear],
        isRoutineAuthority: true,
        onWorkoutApplied: applied.add,
      );
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Apply once at version 3, then deliver a strictly older copy. The stale
      // one writes nothing, so there is nothing new to publish.
      wear.deliver(
        SyncMessage(
          type: workoutCompletedType,
          payload:
              WorkoutCompletedMessage(dtoFor('w-hc', version: 3)).toPayload(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      applied.clear();

      wear.deliver(
        SyncMessage(
          type: workoutCompletedType,
          payload:
              WorkoutCompletedMessage(dtoFor('w-hc', version: 1)).toPayload(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(applied, isEmpty);
      await svc.dispose();
    });
  });

  test('a server-received workout relays to the watch, not back to the server',
      () async {
    final wear = FakeTransport();
    final server = FakeTransport();
    final svc = serviceWith([wear, server], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    wear.sent.clear();
    server.sent.clear();

    final dto = WorkoutDto(
      syncId: 'w-2',
      routineSyncId: null,
      startedAtMs: DateTime.utc(2026, 1, 3).millisecondsSinceEpoch,
      endedAtMs: DateTime.utc(2026, 1, 3, 1).millisecondsSinceEpoch,
      exercises: const [],
      completions: const [],
    );
    server.deliver(
      SyncMessage(
        type: workoutCompletedType,
        payload: WorkoutCompletedMessage(dto).toPayload(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final relayed =
        wear.sent.where((m) => m.type == workoutCompletedType).toList();
    expect(relayed, hasLength(1));
    expect(relayed.first.payload['syncId'], 'w-2');
    expect(server.sent.where((m) => m.type == workoutCompletedType), isEmpty);
    await svc.dispose();
  });

  test('authority pushes a versioned tombstone when a routine is deleted',
      () async {
    final routineId = await _seedRoutine(db);
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700)); // baseline
    t.sent.clear();

    // Soft-delete the routine (leaves a tombstone), then force a context push.
    await db.deleteRoutine(routineId);
    await svc.pushAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Deletion rides inside the ordinary bundle as a tombstone — no separate
    // routine-deleted message.
    final bundles = t.sent.where((m) => m.type == routineBundleType).toList();
    expect(bundles, isNotEmpty);
    final routines =
        RoutineBundleMessage.fromPayload(bundles.last.payload).routines;
    final tomb = routines.firstWhere((r) => r.syncId == 'routine-1');
    expect(tomb.deletedAtMs, isNotNull, reason: 'deletion travels as tombstone');
    expect(tomb.exercises, isEmpty);
    expect(t.sent.where((m) => m.type == routineDeletedType), isEmpty);
    await svc.dispose();
  });

  test('no routine-deleted is sent when a peer routine is merged (no war)',
      () async {
    // Authority holds routine-1, then receives a *different* routine over
    // Firestore. A later push must NOT delete the merged-in peer routine.
    await _seedRoutine(db);
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700)); // baseline
    t.sent.clear();

    final upsert = RoutineBundleMessage([
      RoutineTemplateDto(
        syncId: 'peer-routine',
        name: 'From peer',
        version: 1,
        createdAtMs: DateTime.utc(2026, 1, 3).millisecondsSinceEpoch,
        exercises: const [],
      ),
    ]);
    t.deliver(SyncMessage(type: routineUpsertType, payload: upsert.toPayload()));
    await svc.pushAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(t.sent.where((m) => m.type == routineDeletedType), isEmpty);
    await svc.dispose();
  });

  test('inbound syncRequest makes the authority push context back', () async {
    await _seedRoutine(db);
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    t.sent.clear();

    t.deliver(SyncMessage(type: syncRequestType, payload: const {}));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(t.sent.where((m) => m.type == routineBundleType), isNotEmpty);
    await svc.dispose();
  });

  test('addTransport wires a late transport and pushes current state',
      () async {
    await _seedRoutine(db);
    final first = FakeTransport();
    final svc = serviceWith([first], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final late = FakeTransport();
    svc.addTransport(late);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(late.started, isTrue);
    expect(late.sent.where((m) => m.type == routineBundleType), isNotEmpty);
    await svc.dispose();
  });

  test('dispose tears down transports and stops further delivery', () async {
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: false);
    svc.start();
    await svc.dispose();

    expect(t.disposed, isTrue);
  });

  test('addTransport with pushOnAttach:false attaches receive-only', () async {
    // The account-switch guard: a transport attached for a different account
    // must not have this device's local routines auto-pushed into it.
    await _seedRoutine(db);
    final wear = FakeTransport();
    final svc = serviceWith([wear], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final switched = FakeTransport();
    svc.addTransport(switched, pushOnAttach: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(switched.started, isTrue, reason: 'still listens for inbound state');
    expect(
      switched.sent.where((m) => m.type == routineBundleType),
      isEmpty,
      reason: 'no local routines pushed into the switched-to account',
    );
    await svc.dispose();
  });

  test('removeTransport disposes it and stops fanning sends to it', () async {
    await _seedRoutine(db);
    final wear = FakeTransport();
    final svc = serviceWith([wear], isRoutineAuthority: true);
    svc.start();
    final firestore = FakeTransport();
    svc.addTransport(firestore);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    await svc.removeTransport(firestore);
    expect(firestore.disposed, isTrue);

    wear.sent.clear();
    firestore.sent.clear();
    await svc.pushAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The detached transport receives nothing; the remaining one still does.
    expect(firestore.sent, isEmpty);
    expect(wear.sent.where((m) => m.type == routineBundleType), isNotEmpty);
    await svc.dispose();
  });

  test('removeTransport of an unknown transport is a no-op', () async {
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: false);
    svc.start();

    final stranger = FakeTransport();
    await svc.removeTransport(stranger); // must not throw
    expect(stranger.disposed, isFalse);
    await svc.dispose();
  });

  test('attach -> detach -> re-attach re-pushes state (account switch)',
      () async {
    // Mirrors a uid A -> sign out -> uid B swap at the SyncService layer: each
    // freshly attached transport gets the full local routine set pushed to it.
    await _seedRoutine(db);
    final wear = FakeTransport();
    final svc = serviceWith([wear], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final accountA = FakeTransport();
    svc.addTransport(accountA);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(accountA.sent.where((m) => m.type == routineBundleType), isNotEmpty);

    await svc.removeTransport(accountA);
    final accountB = FakeTransport();
    svc.addTransport(accountB);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(accountA.disposed, isTrue);
    expect(accountB.sent.where((m) => m.type == routineBundleType), isNotEmpty);
    await svc.dispose();
  });

  group('workout edits (version-LWW)', () {
    /// A finished workout with one exercise, one set and one completion.
    Future<String> seedFinishedWorkout(AppDatabase db) async {
      final routineId = await _seedRoutine(db);
      final w = await db.startWorkout(routineId);
      final full = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: full!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 10,
        actualWeightKg: 50,
      );
      await db.finishWorkout(w.syncId);
      return w.syncId;
    }

    List<SyncMessage> workoutSends(FakeTransport t) =>
        t.sent.where((m) => m.type == workoutCompletedType).toList();

    test('editing a finished workout pushes it once, with the new version',
        () async {
      final id = await seedFinishedWorkout(db);
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      await db.updateWorkoutTimes(
        workoutId: id,
        startedAt: DateTime.utc(2026, 2, 1),
        endedAt: DateTime.utc(2026, 2, 1, 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final sends = workoutSends(t);
      expect(sends, hasLength(1));
      final dto = WorkoutCompletedMessage.fromPayload(sends.single.payload);
      expect(dto.workout.syncId, id);
      final row = await (db.select(
        db.workouts,
      )..where((x) => x.syncId.equals(id))).getSingle();
      expect(dto.workout.version, row.version);

      await svc.dispose();
    });

    test('several edits inside the debounce window coalesce into one push',
        () async {
      final id = await seedFinishedWorkout(db);
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      await db.updateWorkoutTimes(
        workoutId: id,
        startedAt: DateTime.utc(2026, 2, 1),
        endedAt: DateTime.utc(2026, 2, 1, 1),
      );
      await db.updateWorkoutTimes(
        workoutId: id,
        startedAt: DateTime.utc(2026, 2, 2),
        endedAt: DateTime.utc(2026, 2, 2, 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(workoutSends(t), hasLength(1));
      await svc.dispose();
    });

    test('deleting a workout pushes the tombstone even though it never ended',
        () async {
      final routineId = await _seedRoutine(db);
      final w = await db.startWorkout(routineId); // no finishWorkout
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      await db.deleteWorkout(w.syncId);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final sends = workoutSends(t);
      expect(sends, hasLength(1));
      final dto = WorkoutCompletedMessage.fromPayload(sends.single.payload);
      expect(dto.workout.deletedAtMs, isNotNull);
      await svc.dispose();
    });

    test('an in-progress workout is not pushed', () async {
      final routineId = await _seedRoutine(db);
      final w = await db.startWorkout(routineId);
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      final full = await db.loadFullWorkout(w.syncId);
      await db.upsertSetCompletion(
        workoutId: w.syncId,
        workoutSetId: full!.exercises.single.sets.single.workoutSet.syncId,
        actualReps: 10,
        actualWeightKg: 50,
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(workoutSends(t), isEmpty);
      await svc.dispose();
    });

    test('applying an inbound workout produces no outbound push', () async {
      // The core anti-loop property: an apply must never look like a local
      // edit to the watcher, or two devices would push each other forever.
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      final dto = WorkoutDto(
        syncId: 'remote-1',
        routineSyncId: null,
        routineName: 'Remote',
        startedAtMs: 1000,
        endedAtMs: 2000,
        version: 3,
        exercises: const [],
        completions: const [],
      );
      t.deliver(
        SyncMessage(
          type: workoutCompletedType,
          payload: WorkoutCompletedMessage(dto).toPayload(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(await db.select(db.workouts).get(), hasLength(1));
      expect(workoutSends(t), isEmpty);
      await svc.dispose();
    });

    test('an inbound workout relays once; a duplicate relays not at all',
        () async {
      final wear = FakeTransport();
      final server = FakeTransport();
      final svc = serviceWith([wear, server], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      wear.sent.clear();
      server.sent.clear();

      final payload = WorkoutCompletedMessage(
        WorkoutDto(
          syncId: 'remote-2',
          routineSyncId: null,
          routineName: 'Remote',
          startedAtMs: 1000,
          endedAtMs: 2000,
          version: 1,
          exercises: const [],
          completions: const [],
        ),
      ).toPayload();

      wear.deliver(SyncMessage(type: workoutCompletedType, payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(workoutSends(server), hasLength(1));
      expect(workoutSends(wear), isEmpty); // never back to the source

      server.sent.clear();
      // Same content again: nothing applied, so nothing relayed.
      wear.deliver(SyncMessage(type: workoutCompletedType, payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(workoutSends(server), isEmpty);

      await svc.dispose();
    });

    test('a strictly older inbound triggers one counter-push of our copy',
        () async {
      final id = await seedFinishedWorkout(db);
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: true);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      // Get our version well above 1.
      await db.updateWorkoutTimes(
        workoutId: id,
        startedAt: DateTime.utc(2026, 3, 1),
        endedAt: DateTime.utc(2026, 3, 1, 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      final stale = WorkoutDto(
        syncId: id,
        routineSyncId: null,
        routineName: 'Stale',
        startedAtMs: 1000,
        endedAtMs: 2000,
        version: 1,
        exercises: const [],
        completions: const [],
      );
      t.deliver(
        SyncMessage(
          type: workoutCompletedType,
          payload: WorkoutCompletedMessage(stale).toPayload(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final sends = workoutSends(t);
      expect(sends, hasLength(1));
      final dto = WorkoutCompletedMessage.fromPayload(sends.single.payload);
      expect(dto.workout.version, greaterThan(1));
      expect(dto.workout.routineName, isNot('Stale'));

      await svc.dispose();
    });

    test('the watch pushes workout edits even though it owns no routines',
        () async {
      final id = await seedFinishedWorkout(db);
      final t = FakeTransport();
      final svc = serviceWith([t], isRoutineAuthority: false);
      svc.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      t.sent.clear();

      await db.updateWorkoutTimes(
        workoutId: id,
        startedAt: DateTime.utc(2026, 4, 1),
        endedAt: DateTime.utc(2026, 4, 1, 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(workoutSends(t), hasLength(1));
      // Still not a routine authority.
      expect(t.sent.where((m) => m.type == routineBundleType), isEmpty);
      await svc.dispose();
    });
  });
}
