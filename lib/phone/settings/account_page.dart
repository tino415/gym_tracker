import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../build_info.dart';
import '../../data/firestore_repositories.dart';
import '../../data/providers.dart';
import '../../privacy_policy.dart';
import '../../sync/account_deletion.dart';
import '../../sync/auth_service.dart';
import '../../sync/health_connect_bridge.dart';
import '../../sync/health_upload_consent.dart';
import '../../sync/sync_ownership.dart';
import '../../sync/sync_service.dart';
import '../breakpoints.dart';
import 'health_connect_controller.dart';
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
      //
      // Capped and centered: this is a column of form controls, and the app's
      // outer cap is sized for the three-pane Routines view, so without this a
      // theme picker and two switches stretch across the whole browser window.
      // A no-op on a phone, where the viewport is already narrower.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: settingsMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
          _AppearanceSection(
            mode: ref.watch(themeModeProvider),
            onChanged: (m) => ref.read(themeModeProvider.notifier).set(m),
          ),
          // A device setting, not an account one — Health Connect lives on this
          // phone — so it sits with Appearance, above the account section, and
          // shows at all only where a provider exists.
          if (ref.watch(healthConnectStatusProvider).valueOrNull ==
              HealthConnectStatus.available) ...[
            const Divider(height: 32),
            _HealthConnectSection(
              enabled: ref.watch(healthConnectEnabledProvider),
              onChanged: (v) =>
                  ref.read(healthConnectEnabledProvider.notifier).set(v),
            ),
          ],
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
              const Divider(height: 32),
              const _BuildStamp(),
            ],
          ),
        ),
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
        // Shown on web too: it writes its documents itself rather than through
        // the transport, but honours the same gate, and withdrawal has to be as
        // easy as consenting (GDPR Art. 7(3)) — a sign-in checkbox alone
        // couldn't be changed without signing out.
        if (!paused) ...[
          const Divider(height: 32),
          _HealthUploadConsentSection(
            granted: healthUploadAllowed(
              consentUid: ref.watch(healthUploadConsentProvider),
              signedInUid: user.uid,
            ),
            onChanged: _busy ? null : (v) => _setHealthUploadConsent(user, v),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : () => _run(auth.signOut, validate: false),
          child: const Text('Sign out'),
        ),
        const Divider(height: 32),
        _DeleteAccountSection(
          onDelete: _busy ? null : () => _deleteAccount(user),
        ),
    ];
  }

  /// Grant or withdraw consent to store heart rate in the account.
  ///
  /// Either way the whole local set is re-pushed, which is what makes the
  /// decision retroactive: the transport strips heart rate from every workout
  /// document it writes while consent is absent, and `set` replaces the
  /// document, so withdrawing removes readings already uploaded rather than
  /// merely stopping new ones. Granting fills them back in.
  Future<void> _setHealthUploadConsent(User user, bool granted) async {
    await _run(() async {
      final consent = ref.read(healthUploadConsentProvider.notifier);
      if (granted) {
        await consent.grant(user.uid);
      } else {
        await consent.revoke();
      }
      // Two ways to reach the same documents. The phone re-pushes its local
      // set through the transport, which rewrites each workout under the new
      // decision; web owns the documents directly and rewrites them itself.
      if (ref.read(firestoreDirectProvider)) {
        if (!granted) {
          final repo = ref.read(workoutRepositoryProvider);
          if (repo is FirestoreWorkoutRepository) {
            await repo.stripStoredHealthData();
          }
        }
      } else {
        await ref.read(syncServiceProvider).pushAll();
      }
    }, validate: false);
  }

  /// Delete the account and its server data, after confirming and proving the
  /// session is fresh.
  ///
  /// Reauthentication happens *before* anything is destroyed. Firebase rejects
  /// `user.delete()` on a stale login, and by then the Firestore data is
  /// already gone — leaving an account that still exists with none of its data.
  /// Asking first means a cancelled or failed confirmation changes nothing.
  Future<void> _deleteAccount(User user) async {
    final direct = ref.read(firestoreDirectProvider);
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (context) => _DeleteAccountDialog(
        email: user.email,
        // The Firestore-direct web build has no local store to offer to erase.
        offerLocalWipe: !direct,
      ),
    );
    if (choice == null || !mounted) return;

    await _run(() async {
      // Step 1: prove freshness. Throws if the user cancels or gets it wrong,
      // which aborts before any deletion.
      final provider = ref.read(authServiceProvider).currentProviderId;
      if (provider == 'password') {
        await ref
            .read(authServiceProvider)
            .reauthenticateWithPassword(choice.password ?? '');
      } else {
        await ref.read(authServiceProvider).reauthenticateWithGoogle();
      }

      // Step 2: server data, then the account. Order matters — the rules key
      // on request.auth.uid, so data must go while the account still exists.
      await ref.read(accountDeletionServiceProvider).deleteAccount();

      // Step 3: local cleanup. The owner marker always goes: it now names a
      // uid that no longer exists, and any future account would be treated as
      // a stranger and left with sync paused forever.
      if (!direct) {
        if (choice.wipeLocal) {
          await ref.read(databaseProvider).clearAllLocalData();
        }
        await ref.read(syncOwnershipStoreProvider).clear();
        ref.invalidate(syncOwnerProvider);
        ref.invalidate(firestoreSyncBinderProvider);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account deleted.')),
      );
    }, validate: false);
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

/// Which build this is, at the very bottom of the settings.
///
/// Deliberately unglamorous and always present. Its job is to answer "is this
/// the bundle I just deployed?" — on web the service worker can keep serving a
/// previous `main.dart.js` long after a deploy, so a fix looks like it never
/// took effect. Comparing this against the commit you shipped settles it.
///
/// Selectable so it can be copied into a bug report, and `dev` on any build made
/// without the Justfile — which is itself the answer when someone is unknowingly
/// running a local debug build.
class _BuildStamp extends StatelessWidget {
  const _BuildStamp();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.tag, size: 16, color: scheme.outline),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            'Build $buildId',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
        ),
      ],
    );
  }
}

/// Opt-in for publishing finished workouts to Health Connect.
///
/// Off by default and never flipped on silently — writing someone's training to
/// a system-wide health store is their call. Turning it on asks Health Connect
/// for permission and stays off if that is refused, so the switch never claims
/// to be publishing when nothing can be written.
class _HealthConnectSection extends StatelessWidget {
  const _HealthConnectSection({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Health Connect', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enabled,
          onChanged: onChanged,
          title: const Text('Write workouts to Health Connect'),
          subtitle: const Text(
            'Finished workouts appear in Health Connect, with heart rate when '
            'a watch recorded it. Nothing is ever read back.',
          ),
        ),
      ],
    );
  }
}

/// Explicit consent to store heart rate — health data — in the account.
///
/// Separate from signing in on purpose. Signing in is the contract that makes
/// routines and history follow you between devices; heart rate is a special
/// category of data under GDPR Art. 9, which that contract does not cover. So
/// it gets its own affirmative act, off until taken, and withdrawable — the
/// switch is the consent record and the withdrawal mechanism both.
class _HealthUploadConsentSection extends StatelessWidget {
  const _HealthUploadConsentSection({
    required this.granted,
    required this.onChanged,
  });

  final bool granted;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Heart rate', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: granted,
          onChanged: onChanged,
          title: const Text('Store heart rate in my account'),
          subtitle: const Text(
            'Heart rate is health data. Off, your workouts still sync but '
            'their readings stay on your devices. On, the readings are stored '
            'with each workout so they appear on your other devices. Turning '
            'it off again deletes the readings already stored.',
          ),
        ),
        // Consent to health data has to be informed, so the policy is
        // reachable from where the decision is made.
        const PrivacyPolicyLink(),
      ],
    );
  }
}

/// What the confirmation dialog came back with. Null instead means cancelled.
class _DeleteChoice {
  const _DeleteChoice({required this.wipeLocal, this.password});

  /// Also erase the routines and history held on this device.
  final bool wipeLocal;

  /// Typed to reauthenticate, for password accounts. Null for Google ones,
  /// which reauthenticate through their own flow instead.
  final String? password;
}

/// The permanent, discoverable way to delete the account — required by Play of
/// any app that lets users create one. Deliberately plain and last on the page,
/// with the consequences spelled out before the dialog rather than after.
class _DeleteAccountSection extends StatelessWidget {
  const _DeleteAccountSection({required this.onDelete});

  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Delete account',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Permanently deletes your account and everything synced to it. '
          'This cannot be undone.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete account'),
          style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
        ),
      ],
    );
  }
}

/// Confirms deletion, collects the password for reauthentication, and offers to
/// clear this device as well.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({
    required this.email,
    required this.offerLocalWipe,
  });

  final String? email;
  final bool offerLocalWipe;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _passwordController = TextEditingController();

  /// Off by default: deleting the account is about the *account*. Someone who
  /// keeps using the app offline afterwards should not silently lose their
  /// training history along with it.
  bool _wipeLocal = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPassword =
        ProviderScope.containerOf(context, listen: false)
                .read(authServiceProvider)
                .currentProviderId ==
            'password';
    return AlertDialog(
      title: const Text('Delete account?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This deletes ${widget.email ?? 'your account'} and every routine, '
              'workout and exercise synced to it. It cannot be undone.',
            ),
            const SizedBox(height: 16),
            if (isPassword) ...[
              Text(
                'Confirm your password to continue.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
            ] else
              Text(
                'You will be asked to sign in again to confirm.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            if (widget.offerLocalWipe) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _wipeLocal,
                onChanged: (v) => setState(() => _wipeLocal = v ?? false),
                title: const Text('Also erase data on this device'),
                subtitle: const Text(
                  'Otherwise your routines and history stay here and the app '
                  'keeps working offline.',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            _DeleteChoice(
              wipeLocal: _wipeLocal,
              password: isPassword ? _passwordController.text : null,
            ),
          ),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: const Text('Delete account'),
        ),
      ],
    );
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
