import 'auth_store.dart';

/// The revoked grant ids, re-read at most once per [refreshEvery] per
/// instance, so a revocation reaches every instance within that time. A
/// revocation made here is visible at once.
class Revocations {
  Revocations(
    this._store, {
    DateTime Function() now = DateTime.now,
    this.refreshEvery = const Duration(seconds: 60),
  }) : _now = now;

  /// Past a token's life, a revoked grant can no longer be used, so its record
  /// may expire: the longest refresh token plus the longest access token.
  static const recordLasts = Duration(days: 30, hours: 1);

  final AuthStore _store;
  final DateTime Function() _now;
  final Duration refreshEvery;
  Set<String> _revoked = {};
  DateTime? _readAt;

  Future<void>? _refreshing;

  Future<bool> isRevoked(String grantId) async {
    final readAt = _readAt;
    if (readAt == null || _now().difference(readAt) >= refreshEvery) {
      await (_refreshing ??= _refresh().whenComplete(() => _refreshing = null));
    }
    return _revoked.contains(grantId);
  }

  Future<void> _refresh() async {
    final read = _now();
    _revoked = {..._revoked, ...await _store.revokedGrantIds(read)};
    _readAt = read;
  }

  Future<void> revoke(String grantId) async {
    await _store.revokeGrant(grantId, _now().add(recordLasts));
    _revoked = {..._revoked, grantId};
  }
}
