import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which sync backend to enable, chosen at build time:
/// `--dart-define=SYNC_BACKEND=firestore`. Empty (the default) keeps the app
/// on Wear-only sync, so ordinary phone/watch builds and tests pull in no
/// Firebase runtime.
const _backend = String.fromEnvironment('SYNC_BACKEND');

/// True only for `--dart-define=SYNC_BACKEND=firestore` builds. UI and auth
/// providers gate on this so plain phone/watch builds never touch FirebaseAuth.
const bool syncBackendEnabled = _backend == 'firestore';

/// Emulator target. Defaults match `firebase.json`. Host is `localhost` so a
/// web build served from the machine reaches the loopback-bound emulator; an
/// Android device would need the host's LAN address instead.
const _emulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: 'localhost',
);
const _firestorePort = int.fromEnvironment(
  'FIRESTORE_EMULATOR_PORT',
  defaultValue: 4120,
);
const _authPort = int.fromEnvironment(
  'AUTH_EMULATOR_PORT',
  defaultValue: 4119,
);

/// Whether to point the SDKs at the local emulator instead of a real Firebase
/// project. Off by default so a production build never silently dials a
/// non-existent localhost emulator; dev/emulator runs opt in explicitly with
/// `--dart-define=FIREBASE_USE_EMULATOR=true`.
const _useEmulator = bool.fromEnvironment('FIREBASE_USE_EMULATOR');

/// Emulator credentials. The `demo-` project id makes every emulator run fully
/// offline — no real Google project, account, or billing. Used only when
/// [_useEmulator] is set; production builds use [_prodOptions].
const _demoOptions = FirebaseOptions(
  apiKey: 'demo-api-key',
  appId: '1:000000000000:web:0000000000000000000000',
  messagingSenderId: '000000000000',
  projectId: 'demo-gym-tracker',
);

/// Production web credentials for the `gym-tracker-44a5f` Firebase project.
/// These are public client identifiers (they ship in the web bundle); access
/// is gated by Firebase Auth + the Firestore rules, not by keeping them secret.
/// `measurementId` is intentionally omitted — Analytics isn't wired up.
const _prodOptions = FirebaseOptions(
  apiKey: 'AIzaSyBv9VFgndG4TTmTqhYy7_xcJUvb76bJqwo',
  appId: '1:15728358407:web:c69d0b9de43bf54da3e6a2',
  messagingSenderId: '15728358407',
  projectId: 'gym-tracker-44a5f',
  authDomain: 'gym-tracker-44a5f.firebaseapp.com',
  storageBucket: 'gym-tracker-44a5f.firebasestorage.app',
);

/// Initialize Firebase and point the SDKs at the emulator. Does **not** sign
/// in — auth is opt-in (see `auth_service.dart`), so a signed-out session makes
/// no Firestore calls at all. Returns true once the app is initialized, false
/// when the backend is disabled or initialization fails (sync then stays
/// Wear-only and the app is otherwise unaffected).
Future<bool> initFirebaseApp() async {
  if (!syncBackendEnabled) return false;
  try {
    await Firebase.initializeApp(
      options: _useEmulator ? _demoOptions : _prodOptions,
    );
  } catch (e, st) {
    debugPrint('Firebase.initializeApp failed: $e\n$st');
    return false;
  }

  if (_useEmulator) {
    // Point auth at the emulator FIRST and in its own guard. If this doesn't
    // apply, sign-in silently hits the production identitytoolkit endpoint and
    // 400s on the demo API key — so a Firestore-emulator hiccup (previously in
    // the same try/catch, ahead of this call) must never prevent it from
    // running. Log failures instead of swallowing them.
    try {
      await FirebaseAuth.instance.useAuthEmulator(_emulatorHost, _authPort);
    } catch (e, st) {
      debugPrint('useAuthEmulator($_emulatorHost:$_authPort) failed: $e\n$st');
    }
    try {
      FirebaseFirestore.instance.useFirestoreEmulator(
        _emulatorHost,
        _firestorePort,
      );
    } catch (e, st) {
      debugPrint(
          'useFirestoreEmulator($_emulatorHost:$_firestorePort) failed: $e\n$st');
    }
  }
  return true;
}

/// One-shot Firebase initialization. Resolves true once the app is ready (or
/// false when the backend is off / init fails). Everything auth-related gates
/// on this so no [FirebaseAuth] call fires before [Firebase.initializeApp].
final firebaseReadyProvider = FutureProvider<bool>((ref) => initFirebaseApp());
