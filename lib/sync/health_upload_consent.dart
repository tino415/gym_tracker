import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
///
/// Kept in SharedPreferences rather than the Drift `SyncMeta` table because the
/// Firestore-direct web build never opens Drift — and web is signed-in by
/// construction, so it is precisely where consent has to be recordable.
class HealthUploadConsentStore {
  const HealthUploadConsentStore();

  static const prefsKey = 'health_upload_consent_uid';

  /// The uid that granted consent, or null if none has.
  ///
  /// A failed read reports "no consent": the safe way to be wrong is to
  /// withhold health data, not to upload it.
  Future<String?> read() async {
    try {
      return (await SharedPreferences.getInstance()).getString(prefsKey);
    } catch (e, st) {
      debugPrint('health consent read failed: $e\n$st');
      return null;
    }
  }

  Future<void> grant(String uid) async =>
      (await SharedPreferences.getInstance()).setString(prefsKey, uid);

  Future<void> revoke() async =>
      (await SharedPreferences.getInstance()).remove(prefsKey);
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

/// Whether a workout document actually carries readings.
///
/// Distinct from "has the keys": a document written under the current codec
/// carries `avgHeartRate: null` and an empty `heartRateSamples` whether or not
/// a sensor was involved, and rewriting those to drop empty keys would bump the
/// version of every workout a user owns for no gain.
bool hasHealthData(Map<String, Object?> workout) {
  if (workout['avgHeartRate'] != null) return true;
  if (workout['maxHeartRate'] != null) return true;
  final samples = workout['heartRateSamples'];
  if (samples is List && samples.isNotEmpty) return true;
  final completions = workout['completions'];
  if (completions is List) {
    for (final c in completions) {
      if (c is Map &&
          (c['avgHeartRate'] != null || c['maxHeartRate'] != null)) {
        return true;
      }
    }
  }
  return false;
}

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
  (ref) => const HealthUploadConsentStore(),
);

/// The uid that has consented, held in memory so the Firestore transport can
/// consult it synchronously on every push.
///
/// Starts null and self-seeds from storage; the sync binder additionally awaits
/// [load] before attaching a transport, so the first push can't race it. The
/// null default means anything that does race reads as "no consent" and strips
/// heart rate rather than uploading it.
class HealthUploadConsent extends Notifier<String?> {
  @override
  String? build() {
    // Fire-and-forget so web — which has no binder step to await it — still
    // ends up with the persisted decision in memory.
    unawaited(load());
    return null;
  }

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
