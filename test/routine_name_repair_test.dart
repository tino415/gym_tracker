import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/firestore_repositories.dart';
import 'package:gym_tracker/data/routine_name_repair.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The once-per-account guard around the embedded-name repair. The repair
/// itself is covered in `firestore_routine_repository_test.dart`; what matters
/// here is that it runs exactly once, and that a failure is *not* recorded as
/// done.
void main() {
  late FakeFirebaseFirestore fs;
  late FirestoreRoutineRepository routines;
  late FirestoreExerciseRepository exercises;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fs = FakeFirebaseFirestore();
    routines = FirestoreRoutineRepository(uid: 'u1', firestore: fs);
    exercises = FirestoreExerciseRepository(uid: 'u1', firestore: fs);
  });

  /// A routine whose embedded name is stale, as every routine was before the
  /// rename fan-out existed.
  Future<String> seedStaleRoutine() async {
    final ex = await exercises.createExercise('Old name');
    final r = await routines.createRoutine('Pull');
    await routines.addExerciseToRoutine(
      routineId: r.syncId,
      exerciseId: ex.syncId,
    );
    await fs
        .collection('users')
        .doc('u1')
        .collection('exercises')
        .doc(ex.syncId)
        .update({'name': 'New name'});
    return r.syncId;
  }

  Future<String> embeddedName(String routineId) async {
    final doc =
        await fs.collection('users').doc('u1').collection('routines').doc(routineId).get();
    final slots = doc.data()!['exercises'] as List;
    return (slots.single as Map)['exerciseName'] as String;
  }

  test('repairs on the first run and records the account', () async {
    final id = await seedStaleRoutine();

    await repairRoutineNamesOnce(uid: 'u1', routines: routines);

    expect(await embeddedName(id), 'New name');
    expect(await const RoutineNameRepairMarker().isDone('u1'), isTrue);
  });

  test('does not scan again once the account is marked', () async {
    await const RoutineNameRepairMarker().markDone('u1');
    final id = await seedStaleRoutine();

    await repairRoutineNamesOnce(uid: 'u1', routines: routines);

    // Untouched: the marker short-circuits before any read.
    expect(await embeddedName(id), 'Old name');
  });

  test('the marker is per-account', () async {
    await const RoutineNameRepairMarker().markDone('someone-else');
    final id = await seedStaleRoutine();

    await repairRoutineNamesOnce(uid: 'u1', routines: routines);

    expect(await embeddedName(id), 'New name');
    expect(await const RoutineNameRepairMarker().isDone('someone-else'), isTrue);
  });

  test('a failed repair is not recorded, so the next start retries', () async {
    await seedStaleRoutine();
    // A repository whose collections throw: stands in for an offline start or a
    // rules rejection. Recording that as "done" would strand the stale names.
    final broken = FirestoreRoutineRepository(uid: 'u1', firestore: _ThrowingFirestore());

    await repairRoutineNamesOnce(uid: 'u1', routines: broken);

    expect(await const RoutineNameRepairMarker().isDone('u1'), isFalse);
  });
}

/// Fails every read, to exercise the "leave the marker unset" path.
class _ThrowingFirestore extends FakeFirebaseFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      throw StateError('offline');
}
