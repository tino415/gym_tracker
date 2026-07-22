import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sync/auth_service.dart';

/// Opt-in "Sync & backup" account screen. Signed out, it offers email/password
/// sign-in (a Google button appears only when [googleSignInSupported], which is
/// currently false — see auth_service.dart); signed in, it shows the account and
/// a sign-out button. Reaching this page from the Routines app bar is the only place the
/// user turns server sync on — the [firestoreSyncBinderProvider] attaches the
/// Firestore transport reactively once sign-in succeeds.
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Run an auth action with the busy flag set, validating the form first for
  /// the flows that need it. Surfaces failures as a snackbar.
  Future<void> _run(Future<void> Function() action, {bool validate = true}) async {
    if (validate && !_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await action();
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

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(authBackendEnabledProvider);
    final userAsync = ref.watch(authStateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: !enabled
          ? const _DisabledNotice()
          : userAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (user) =>
                  user == null ? _buildSignedOut() : _buildSignedIn(user),
            ),
    );
  }

  Widget _buildSignedOut() {
    final auth = ref.read(authServiceProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Sign in to sync your routines and history across devices. '
          'The app stays fully usable without an account.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 16),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
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
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if ((v ?? '').length < 6) {
                    return 'At least 6 characters';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(
                  () => auth.signInWithEmail(
                    _emailController.text.trim(),
                    _passwordController.text,
                  ),
                ),
          child: const Text('Sign in'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(
                  () => auth.registerWithEmail(
                    _emailController.text.trim(),
                    _passwordController.text,
                  ),
                ),
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
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
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
    );
  }

  Widget _buildSignedIn(User user) {
    final auth = ref.read(authServiceProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle),
          title: Text(user.email ?? 'Signed in'),
          subtitle: SelectableText(user.uid),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : () => _run(auth.signOut, validate: false),
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _DisabledNotice extends StatelessWidget {
  const _DisabledNotice();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Cloud sync is not enabled in this build.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }
}
