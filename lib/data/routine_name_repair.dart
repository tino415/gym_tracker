import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firestore_repositories.dart';

/// Runs [FirestoreRoutineRepository.repairEmbeddedExerciseNames] once per
/// account, on the web build.
///
/// Renames used to touch only the exercise document, so every routine kept the
/// `exerciseName` it was created with. The repair itself is idempotent — it
/// writes nothing when the library and the embedded copies already agree — but
/// it scans two collections to find that out, and paying ~100 document reads on
/// every app start for a one-time fix is not worth it. Hence the marker.
///
/// **This is deletable** once every account that predates the fan-out has opened
/// the web app once. It is a data migration, not a feature.
///
/// The marker lives in SharedPreferences rather than Firestore so the check
/// itself costs no reads, and per-uid so one account's repair is never read as
/// another's on a shared browser — mirroring `health_upload_consent.dart` and
/// `sync_ownership.dart`. Consequence: a different browser profile re-runs the
/// scan once and finds nothing to do, which is the cheap direction to be wrong.
class RoutineNameRepairMarker {
  const RoutineNameRepairMarker();

  static const prefsKey = 'routine_embedded_names_repaired_uids';

  Future<bool> isDone(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(prefsKey) ?? const []).contains(uid);
    } catch (e, st) {
      // A failed read means "not done", so the repair runs again. Re-running is
      // free of side effects; skipping it leaves routines stale.
      debugPrint('routine name repair marker read failed: $e\n$st');
      return false;
    }
  }

  Future<void> markDone(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getStringList(prefsKey) ?? const <String>[];
      if (done.contains(uid)) return;
      await prefs.setStringList(prefsKey, [...done, uid]);
    } catch (e, st) {
      debugPrint('routine name repair marker write failed: $e\n$st');
    }
  }
}

/// Repairs [uid]'s routines unless it has already been done on this install.
///
/// Marked done even when nothing needed rewriting: the question the marker
/// answers is "has this account been scanned", not "was anything broken".
Future<void> repairRoutineNamesOnce({
  required String uid,
  required FirestoreRoutineRepository routines,
  RoutineNameRepairMarker marker = const RoutineNameRepairMarker(),
}) async {
  if (await marker.isDone(uid)) return;
  try {
    final repaired = await routines.repairEmbeddedExerciseNames();
    if (repaired > 0) {
      debugPrint('repaired embedded exercise names in $repaired routine(s)');
    }
  } catch (e, st) {
    // Leave the marker unset so the next start retries. A failed repair must not
    // be recorded as done, or the stale names would survive forever.
    debugPrint('routine name repair failed: $e\n$st');
    return;
  }
  await marker.markDone(uid);
}
