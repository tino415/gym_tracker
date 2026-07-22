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

/// Placeholder credentials. The `demo-` project id makes every emulator run
/// fully offline — no real Google project, account, or billing. Replaced with
/// generated FirebaseOptions when production hosting is set up.
const _demoOptions = FirebaseOptions(
  apiKey: 'demo-api-key',
  appId: '1:000000000000:web:0000000000000000000000',
  messagingSenderId: '000000000000',
  projectId: 'demo-gym-tracker',
);

/// Initialize Firebase and point the SDKs at the emulator. Does **not** sign
/// in — auth is opt-in (see `auth_service.dart`), so a signed-out session makes
/// no Firestore calls at all. Returns true once the app is initialized, false
/// when the backend is disabled or initialization fails (sync then stays
/// Wear-only and the app is otherwise unaffected).
Future<bool> initFirebaseApp() async {
  if (!syncBackendEnabled) return false;
  try {
    await Firebase.initializeApp(options: _demoOptions);

    if (_useEmulator) {
      FirebaseFirestore.instance.useFirestoreEmulator(
        _emulatorHost,
        _firestorePort,
      );
      await FirebaseAuth.instance.useAuthEmulator(_emulatorHost, _authPort);
    }
    return true;
  } catch (e, st) {
    debugPrint('Firebase init failed: $e\n$st');
    return false;
  }
}

/// One-shot Firebase initialization. Resolves true once the app is ready (or
/// false when the backend is off / init fails). Everything auth-related gates
/// on this so no [FirebaseAuth] call fires before [Firebase.initializeApp].
final firebaseReadyProvider = FutureProvider<bool>((ref) => initFirebaseApp());
