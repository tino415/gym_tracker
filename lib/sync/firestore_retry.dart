import 'package:cloud_firestore/cloud_firestore.dart';

/// How many times a failure that is *usually* permanent still gets another go.
///
/// Two cases need it. A read issued right after sign-in can come back
/// `permission-denied` simply because the auth token has not reached the
/// backend yet, and the transport attaches and reads at exactly that moment. And
/// a failure that is not Firestore's at all — a Drift exception on the phone
/// path, say — cannot be classified here, so it gets a few tries rather than
/// either an infinite loop or an immediate surrender.
const _uncertainAttempts = 3;

/// Whether retrying a failed call could still succeed on attempt [attempt].
///
/// Retry loops here run for the life of the process, so this is not cosmetic: a
/// rules mismatch or a wrong uid fails identically every time, and re-issuing a
/// whole-collection read every thirty seconds forever costs battery and quota to
/// learn nothing.
bool isRetryableFirestoreFailure(Object error, {int attempt = 1}) {
  // Not Firestore's, so nothing here can tell transient from fatal. A Drift
  // failure on the phone seed path is the realistic one, and it repeats
  // identically, so this must not become an unbounded loop.
  if (error is! FirebaseException) return attempt <= _uncertainAttempts;

  return switch (error.code) {
    // Often just the token catching up, sometimes genuinely wrong rules.
    'permission-denied' || 'unauthenticated' => attempt <= _uncertainAttempts,
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
