import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';

String authErrorText(BuildContext context, FirebaseAuthException e) {
  final l10n = context.l10n;
  return switch (e.code) {
    'missing-google-id-token' => l10n.syncGoogleNoIdToken,
    'no-email-credential' => l10n.syncNoEmailCredential,
    'no-current-user' => l10n.syncNotSignedIn,
    _ => e.message ?? e.code,
  };
}
