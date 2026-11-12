import 'dart:io';

import 'account_directory.dart';
import 'config.dart';
import 'request_budget.dart';

sealed class AuthOutcome {}

class Authenticated extends AuthOutcome {
  Authenticated(this.account);

  final VerifiedAccount account;
}

class Rejected extends AuthOutcome {
  Rejected(this.reason);

  final String reason;
}

class Throttled extends AuthOutcome {
  Throttled(this.retryAfter);

  final Duration retryAfter;
}

/// Every check that costs nothing comes before the first call to Google, so a
/// flood of requests with a wrong token or over the budget reads nothing.
class StaticTokenAuthenticator {
  StaticTokenAuthenticator(this._token, this._accounts, this._budget);

  final StaticToken _token;
  final AccountDirectory _accounts;
  final RequestBudget _budget;

  Future<AuthOutcome> authenticate(HttpHeaders headers) async {
    final presented = _bearerToken(
      headers.value(HttpHeaders.authorizationHeader),
    );
    if (presented == null) return Rejected('missing bearer token');
    if (presented != _token.value) return Rejected('invalid token');
    final wait = _budget.spend();
    if (wait != null) return Throttled(wait);
    final uid = _token.uid ?? await _accounts.soleUid();
    if (uid == null) return Rejected('no emulator account to map the token to');
    final account = await _accounts.verify(uid);
    return account == null
        ? Rejected('account does not exist or is disabled')
        : Authenticated(account);
  }

  String? _bearerToken(String? header) {
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return null;
    return header.substring(prefix.length).trim();
  }
}
