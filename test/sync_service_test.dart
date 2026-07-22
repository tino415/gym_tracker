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

Future<int> _seedRoutine(AppDatabase db, {String name = 'Push day'}) async {
  final routineId = await db
      .into(db.routines)
      .insert(
        RoutinesCompanion.insert(
          syncId: 'routine-1',
          name: name,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
  final exerciseId = await db
      .into(db.exercises)
      .insert(
        ExercisesCompanion.insert(
          syncId: 'ex-1',
          name: 'Bench Press',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
  final reId = await db
      .into(db.routineExercises)
      .insert(
        RoutineExercisesCompanion.insert(
          syncId: 're-1',
          routineId: routineId,
          exerciseId: exerciseId,
          orderIndex: 0,
        ),
      );
  await db
      .into(db.plannedSets)
      .insert(
        PlannedSetsCompanion.insert(
          syncId: 'ps-1',
          routineExerciseId: reId,
          setIndex: 0,
          targetReps: const Value(10),
          targetWeightKg: const Value(50),
        ),
      );
  return routineId;
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
  }) {
    return SyncService(
      db,
      repo,
      isRoutineAuthority: isRoutineAuthority,
      transports: transports,
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

  test('authority emits routine-deleted when a routine disappears between '
      'pushes', () async {
    final routineId = await _seedRoutine(db);
    final t = FakeTransport();
    final svc = serviceWith([t], isRoutineAuthority: true);
    svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 700)); // baseline
    t.sent.clear();

    // Delete the routine, then force another context push.
    await (db.delete(db.routines)..where((r) => r.id.equals(routineId))).go();
    await svc.pushAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final deletes = t.sent.where((m) => m.type == routineDeletedType).toList();
    expect(deletes, isNotEmpty, reason: 'deletion must be sent explicitly');
    expect(
      (deletes.first.payload['syncIds'] as List).cast<String>(),
      contains('routine-1'),
    );
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
}
