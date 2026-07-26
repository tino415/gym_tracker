import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../sync/auth_service.dart';
import '../../sync/sync_ownership.dart';
import 'theme_controller.dart';

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
      // Single scroll view: the Appearance section is always shown (it isn't
      // gated on sync being enabled or the user being signed in); the account /
      // sync content follows below it.
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AppearanceSection(
            mode: ref.watch(themeModeProvider),
            onChanged: (m) => ref.read(themeModeProvider.notifier).set(m),
          ),
          const Divider(height: 32),
          if (!enabled)
            const _DisabledNotice()
          else
            ...userAsync.when(
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [Center(child: Text('Error: $e'))],
              data: (user) =>
                  user == null ? _signedOutChildren() : _signedInChildren(user),
            ),
        ],
      ),
    );
  }

  List<Widget> _signedOutChildren() {
    final auth = ref.read(authServiceProvider);
    return [
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
    ];
  }

  List<Widget> _signedInChildren(User user) {
    final auth = ref.read(authServiceProvider);
    // Whether server sync is paused because this device's local data belongs to
    // a different account. Owner null (unclaimed) or matching means active sync.
    // The Firestore-direct web build has no local store (the account *is* the
    // store), so there's no owner/paused concept — and reading syncOwnerProvider
    // there would spin up an unwanted local Drift database.
    final direct = ref.watch(firestoreDirectProvider);
    final owner = direct ? null : ref.watch(syncOwnerProvider).valueOrNull;
    final paused = owner != null && owner != user.uid;
    return [
        ListTile(
          leading: const Icon(Icons.account_circle),
          title: Text(user.email ?? 'Signed in'),
          subtitle: SelectableText(user.uid),
        ),
        if (paused) ...[
          const SizedBox(height: 16),
          _PausedSyncCard(
            onClaim: _busy ? null : () => _claimDevice(user.uid),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : () => _run(auth.signOut, validate: false),
          child: const Text('Sign out'),
        ),
    ];
  }

  /// Take over this device for the signed-in account: persist it as the sync
  /// owner and rebuild the binder so a full transport attaches and pushes the
  /// local data up. Nothing local is deleted — the data (which may still hold
  /// the previous owner's rows) is merged up into this account.
  Future<void> _claimDevice(String uid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use this account here?'),
        content: const Text(
          'This starts syncing the data currently on this device to the '
          'signed-in account. If the device was previously used by another '
          'account, that account\'s routines and history may be uploaded too. '
          'Nothing is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use this account'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(syncOwnershipStoreProvider).write(uid);
      // Rebuild the binder (re-reads the owner, now this uid, and attaches a
      // pushing transport) and refresh the owner the notice reads.
      ref.invalidate(firestoreSyncBinderProvider);
      ref.invalidate(syncOwnerProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Notice shown when server sync is paused because the local data belongs to a
/// different account, with the action to claim the device for the current one.
class _PausedSyncCard extends StatelessWidget {
  const _PausedSyncCard({required this.onClaim});

  final VoidCallback? onClaim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync_disabled, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Cloud sync is paused',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'This device\'s data belongs to a different account, so nothing '
              'syncs while you\'re signed in here. Use this account on this '
              'device to start syncing.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onClaim,
                child: const Text('Use this account on this device'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App theme picker (System / Light / Dark), shown on the settings screen
/// regardless of auth state. Reads/writes [themeModeProvider] via [onChanged].
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Theme',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
            ],
            selected: {mode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => onChanged(s.first),
          ),
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
