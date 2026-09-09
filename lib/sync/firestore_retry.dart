import 'package:cloud_firestore/cloud_firestore.dart';

/// Whether retrying a failed Firestore call could ever succeed.
///
/// Retry loops here run for the life of the process, so the distinction is not
/// cosmetic: a rules mismatch or a wrong uid fails identically every time, and
/// re-issuing a whole-collection read every 30 seconds forever costs battery
/// and quota to learn nothing. Anything unrecognised is treated as retryable,
/// because giving up on a transient failure strands data and giving up late on
/// a permanent one only wastes a few attempts.
bool isRetryableFirestoreFailure(Object error) {
  if (error is! FirebaseException) return true;
  return switch (error.code) {
    'permission-denied' ||
    'unauthenticated' ||
    'invalid-argument' ||
    'not-found' ||
    'already-exists' ||
    'failed-precondition' ||
    'out-of-range' ||
    'unimplemented' =>
      false,
    _ => true,
  };
}

/// Backoff for those loops: grows, then holds. Capped rather than unbounded so
/// a connection that comes back after an hour is picked up in under a minute.
Duration firestoreRetryDelay(int attempt) {
  const cap = Duration(seconds: 30);
  // Clamped at 6 so the shift reaches 32s and the cap is the thing that
  // actually bounds it. Clamping lower would top out under the cap and leave
  // it dead code.
  final seconds = 1 << (attempt.clamp(1, 6) - 1);
  final d = Duration(seconds: seconds);
  return d > cap ? cap : d;
}
