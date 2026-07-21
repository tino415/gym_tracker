import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_transport.dart';
import 'sync_service.dart';

/// Which sync backend to enable, chosen at build time:
/// `--dart-define=SYNC_BACKEND=firestore`. Empty (the default) keeps the app
/// on Wear-only sync, so ordinary phone/watch builds and tests pull in no
/// Firebase runtime.
const _backend = String.fromEnvironment('SYNC_BACKEND');

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

/// Initialize Firebase, point the SDKs at the emulator, and sign in so a uid
/// is available, then hand back a transport bound to that uid. Returns null
/// when the backend is disabled or initialization fails — sync then stays
/// Wear-only and the app is otherwise unaffected.
Future<FirestoreSyncTransport?> initFirestoreBackend() async {
  if (_backend != 'firestore') return null;
  try {
    await Firebase.initializeApp(options: _demoOptions);

    if (_useEmulator) {
      FirebaseFirestore.instance.useFirestoreEmulator(
        _emulatorHost,
        _firestorePort,
      );
      await FirebaseAuth.instance.useAuthEmulator(_emulatorHost, _authPort);
    }

    // Sign-in is anonymous for now; the opt-in Google / email flow is a later
    // epic step. A stable uid per install is enough to exercise the transport.
    final auth = FirebaseAuth.instance;
    final user =
        auth.currentUser ?? (await auth.signInAnonymously()).user;
    if (user == null) return null;

    return FirestoreSyncTransport(uid: user.uid);
  } catch (e, st) {
    debugPrint('Firestore backend init failed: $e\n$st');
    return null;
  }
}

/// Drives one-time backend initialization and attaches the resulting transport
/// to the running [SyncService]. Watched (fire-and-forget) from the app root;
/// its error/loading states are intentionally not surfaced in the UI.
final firestoreBackendProvider = FutureProvider<bool>((ref) async {
  final transport = await initFirestoreBackend();
  if (transport == null) return false;
  ref.read(syncServiceProvider).addTransport(transport);
  return true;
});
