import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';

/// Explicit consent to store heart rate — health data — in the account's cloud
/// storage.
///
/// Heart rate is a special category of personal data under GDPR Art. 9, and
/// signing in is a contract, not consent: the account exists so routines and
/// history reach the user's other devices, and nothing about that act implies
/// agreement to put health data on a server. So the upload is gated on its own
/// affirmative opt-in, off until granted, withdrawable at any time
/// (Art. 7(3)) — and withdrawing removes what was already uploaded, because a
/// re-push overwrites each workout document with a payload that no longer
/// carries the readings.
///
/// This gates the **server** only. Heart rate still moves phone ↔ watch over
/// the Wear Data Layer, which is a direct link between two of the user's own
/// devices and never reaches us — see [stripHealthData], which is applied in
/// the Firestore transport rather than at export for exactly that reason.
///
/// Stored per-uid (not as a bare bool) so consent given by one account is never
/// read as consent by another on a shared install, mirroring how
/// `sync_ownership.dart` keys the store owner.
class HealthUploadConsentStore {
  HealthUploadConsentStore(this._db);

  static const _key = 'health_upload_consent_uid';

  final AppDatabase _db;

  /// The uid that granted consent, or null if none has.
  Future<String?> read() => _db.getSyncMeta(_key);

  Future<void> grant(String uid) => _db.setSyncMeta(_key, uid);

  Future<void> revoke() => _db.clearSyncMeta(_key);
}

/// Whether heart rate may be uploaded: consent must exist *and* belong to the
/// account currently signed in.
///
/// Pure so the rule is unit-testable without Firebase — the interesting cases
/// are the null ones and the account switch, and getting either wrong uploads
/// health data nobody agreed to.
bool healthUploadAllowed({
  required String? consentUid,
  required String? signedInUid,
}) =>
    consentUid != null && signedInUid != null && consentUid == signedInUid;

/// Removes every heart-rate field from a workout document.
///
/// Operates on the serialized `WorkoutDto` map rather than the DTO so it can sit
/// at the transport boundary, and covers both the workout-level readings
/// (`heartRateSamples`, `avgHeartRate`, `maxHeartRate`) and the per-set copies
/// carried inside `completions`. Missing keys are fine — this runs on payloads
/// from peers too.
Map<String, Object?> stripHealthData(Map<String, Object?> workout) {
  final out = Map<String, Object?>.from(workout)
    ..remove('heartRateSamples')
    ..remove('avgHeartRate')
    ..remove('maxHeartRate');
  final completions = out['completions'];
  if (completions is List) {
    out['completions'] = [
      for (final c in completions)
        if (c is Map)
          Map<String, Object?>.from(c.cast<String, Object?>())
            ..remove('avgHeartRate')
            ..remove('maxHeartRate')
        else
          c,
    ];
  }
  return out;
}

final healthUploadConsentStoreProvider = Provider<HealthUploadConsentStore>(
  (ref) => HealthUploadConsentStore(ref.watch(databaseProvider)),
);

/// The uid that has consented, held in memory so the Firestore transport can
/// consult it synchronously on every push.
///
/// Starts null and is loaded by the sync binder before a transport is attached
/// — the null default means a push that races the load strips heart rate rather
/// than uploading it.
class HealthUploadConsent extends Notifier<String?> {
  @override
  String? build() => null;

  HealthUploadConsentStore get _store =>
      ref.read(healthUploadConsentStoreProvider);

  /// Read the persisted decision into memory. Awaited before attaching.
  Future<void> load() async => state = await _store.read();

  Future<void> grant(String uid) async {
    await _store.grant(uid);
    state = uid;
  }

  Future<void> revoke() async {
    await _store.revoke();
    state = null;
  }
}

final healthUploadConsentProvider =
    NotifierProvider<HealthUploadConsent, String?>(HealthUploadConsent.new);
