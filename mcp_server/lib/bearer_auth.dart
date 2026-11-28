import 'dart:io';

import 'account_directory.dart';
import 'config.dart';
import 'oauth/jwt.dart';
import 'oauth/revocations.dart';
import 'request_budget.dart';

sealed class AuthOutcome {}

class Authenticated extends AuthOutcome {
  Authenticated(this.account, {required this.canSave});

  final VerifiedAccount account;
  final bool canSave;
}

class Rejected extends AuthOutcome {
  Rejected(this.reason, {required this.tokenPresented});

  final String reason;
  final bool tokenPresented;
}

class Throttled extends AuthOutcome {
  Throttled(this.retryAfter);

  final Duration retryAfter;
}

/// Every check that costs nothing comes before the first call to Google, so a
/// flood of requests with a forged or expired token reads nothing, and one
/// over a budget reads nothing either. The revoked-grant list is read at most
/// once a minute, and Firebase Auth is asked about an account at most once a
/// minute.
class BearerAuthenticator {
  BearerAuthenticator({
    required AccessTokens tokens,
    required Revocations revocations,
    required AccountDirectory accounts,
    required KeyedBudgets perAccount,
    required RequestBudget overall,
    StaticToken? devToken,
  }) : _tokens = tokens,
       _revocations = revocations,
       _accounts = accounts,
       _perAccount = perAccount,
       _overall = overall,
       _devToken = devToken;

  final AccessTokens _tokens;
  final Revocations _revocations;
  final AccountDirectory _accounts;
  final KeyedBudgets _perAccount;
  final RequestBudget _overall;
  final StaticToken? _devToken;

  Future<AuthOutcome> authenticate(HttpHeaders headers) async {
    final presented = _bearerToken(
      headers.value(HttpHeaders.authorizationHeader),
    );
    if (presented == null) {
      return Rejected('missing bearer token', tokenPresented: false);
    }
    final dev = _devToken;
    if (dev != null && presented == dev.value) return _authenticateDev(dev);
    final claims = _tokens.verify(presented);
    if (claims == null) return Rejected('invalid token', tokenPresented: true);
    final overallWait = _overall.spend();
    if (overallWait != null) return Throttled(overallWait);
    if (await _revocations.isRevoked(claims.grantId)) {
      return Rejected('grant revoked', tokenPresented: true);
    }
    final wait = _perAccount.spend(claims.uid);
    if (wait != null) return Throttled(wait);
    return _accountOutcome(
      await _accounts.verify(claims.uid),
      canSave: claims.canSave,
    );
  }

  Future<AuthOutcome> _authenticateDev(StaticToken dev) async {
    final overallWait = _overall.spend();
    if (overallWait != null) return Throttled(overallWait);
    final uid = dev.uid ?? await _accounts.soleUid();
    if (uid == null) {
      return Rejected(
        'no emulator account to map the token to',
        tokenPresented: true,
      );
    }
    final wait = _perAccount.spend(uid);
    if (wait != null) return Throttled(wait);
    return _accountOutcome(await _accounts.verify(uid), canSave: true);
  }

  AuthOutcome _accountOutcome(
    VerifiedAccount? account, {
    required bool canSave,
  }) => account == null
      ? Rejected('account does not exist or is disabled', tokenPresented: true)
      : Authenticated(account, canSave: canSave);

  String? _bearerToken(String? header) {
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return null;
    return header.substring(prefix.length).trim();
  }
}
