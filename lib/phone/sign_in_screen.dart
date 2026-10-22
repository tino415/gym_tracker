import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../l10n/language_picker.dart';
import '../privacy_policy.dart';
import '../sync/auth_service.dart';
import '../sync/health_upload_consent.dart';

/// Full-screen sign-in gate for the server-backed web build. Web reads and
/// writes the account's data directly, so it is signed-in by construction:
/// there is no local-only mode to strand edits in. Shown by the app root when
/// [firestoreDirectProvider] is true and no user is signed in; once sign-in
/// succeeds, [authStateProvider] emits and the root swaps in the app.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;

  /// Opt-in to storing heart rate — health data — in the account.
  ///
  /// Off by default and never a condition of signing in: consent that is the
  /// price of using the app is not freely given (GDPR Art. 7(4)), and web is
  /// signed-in by construction. Leaving it unchecked signs in normally.
  bool _storeHeartRate = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {bool validate = true}) async {
    if (validate && !_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await action();
      await _recordConsentChoice();
      // Sign-in submitted successfully — tell the platform the autofill context
      // is complete so password managers can offer to save the credentials.
      TextInput.finishAutofillContext();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message ?? e.code)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Record the heart-rate opt-in against the account that just signed in.
  ///
  /// Only ever *grants*. An unchecked box leaves any stored decision alone
  /// rather than revoking it: the box is an opt-in offered at sign-in, and a
  /// returning user who already consented should not have that silently undone
  /// by a default. Withdrawal lives on the Account screen, where the switch
  /// shows the real state.
  Future<void> _recordConsentChoice() async {
    if (!_storeHeartRate) return;
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    await ref.read(healthUploadConsentProvider.notifier).grant(uid);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authServiceProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Align(
                alignment: Alignment.centerRight,
                child: SizedBox(width: 180, child: LanguagePicker()),
              ),
              Icon(Icons.fitness_center, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'GymTracker',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in to manage your routines and history.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 24),
              Form(
                key: _formKey,
                // Group the fields so a password manager treats them as one
                // credential (autofill + save-on-submit via
                // finishAutofillContext in _run).
                child: AutofillGroup(
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return 'Email is required';
                          if (!value.contains('@')) return 'Enter a valid email';
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) =>
                            (v ?? '').length < 6 ? 'At least 6 characters' : null,
                        // Enter submits sign-in (keyboard-first desktop), guarded
                        // by the busy flag so it can't double-fire.
                        onFieldSubmitted: (_) {
                          if (_busy) return;
                          _run(() => auth.signInWithEmail(
                                _emailController.text.trim(),
                                _passwordController.text,
                              ));
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: _storeHeartRate,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _storeHeartRate = v ?? false),
                title: const Text('Store heart rate in my account'),
                subtitle: Text(
                  'Heart rate is health data. Leave this off and your workouts '
                  'still sync — their readings just stay on your devices. You '
                  'can change it any time on the Account screen.',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              ),
              // Consent to health data has to be informed, so the policy is
              // reachable from where the decision is made.
              const PrivacyPolicyLink(),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => auth.signInWithEmail(
                          _emailController.text.trim(),
                          _passwordController.text,
                        )),
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign in'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => auth.registerWithEmail(
                          _emailController.text.trim(),
                          _passwordController.text,
                        )),
                child: const Text('Create account'),
              ),
              if (googleSignInSupported) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'or',
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(auth.signInWithGoogle, validate: false),
                  icon: const Icon(Icons.login),
                  label: const Text('Continue with Google'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
