import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';

/// Which account "owns" this install's local Drift store, persisted across
/// restarts. Server-backed sync only runs for the owning account; any other
/// signed-in account leaves the Firestore transport detached (sync paused), so
/// this device never pushes the owner's data into a different account and never
/// downloads a different account's data on top of it. The user can explicitly
/// take over via the account page — see [decideSyncOwnership] and the binder in
/// `auth_service.dart`.
///
/// This is *defensive hardening*, not true multi-account isolation: the local
/// store stays single and global, so a non-owner sign-in still sees whatever the
/// previous owner left behind. Real per-account scoping is deferred to the
/// version-based authority rework.
class SyncOwnershipDecision {
  const SyncOwnershipDecision({required this.attach, this.newOwner});

  /// Whether to attach a full-duplex Firestore transport for the signing-in
  /// account. False means sync stays paused (a different account owns the store).
  final bool attach;

  /// The uid to persist as the new owner, or null to leave the marker unchanged.
  /// Non-null only on first adoption (an install with no owner yet).
  final String? newOwner;
}

/// Decide what happens when [uid] signs in, given the persisted [owner] of this
/// install's local data:
///
/// - no owner yet → attach and adopt [uid] (first sign-in imports local data —
///   the settled guest-data behaviour);
/// - same account → attach, owner unchanged (backup/re-push + download);
/// - different account → do not attach; sync stays paused until the user
///   explicitly claims the device for [uid].
SyncOwnershipDecision decideSyncOwnership(String? owner, String uid) {
  if (owner == null) {
    return SyncOwnershipDecision(attach: true, newOwner: uid);
  }
  if (owner == uid) {
    return const SyncOwnershipDecision(attach: true);
  }
  return const SyncOwnershipDecision(attach: false);
}

/// Persists the sync-owner uid in the Drift [SyncMeta] table. Kept in the DB the
/// app already uses on every platform, rather than a separate plugin.
class SyncOwnershipStore {
  SyncOwnershipStore(this._db);

  static const _ownerKey = 'owner_uid';

  final AppDatabase _db;

  Future<String?> read() => _db.getSyncMeta(_ownerKey);

  Future<void> write(String uid) => _db.setSyncMeta(_ownerKey, uid);
}

/// Shared [SyncOwnershipStore] so the binder and the account page agree on the
/// same persisted marker (both go through the one [AppDatabase]).
final syncOwnershipStoreProvider = Provider<SyncOwnershipStore>(
  (ref) => SyncOwnershipStore(ref.watch(databaseProvider)),
);

/// The persisted owner uid, for UI to compare against the signed-in account and
/// show/hide the "sync paused" notice. Invalidate it after a claim to refresh.
final syncOwnerProvider = FutureProvider<String?>(
  (ref) => ref.watch(syncOwnershipStoreProvider).read(),
);
