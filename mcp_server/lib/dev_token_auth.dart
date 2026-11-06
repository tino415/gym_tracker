import 'dart:io';

import 'account_directory.dart';
import 'config.dart';

sealed class AuthOutcome {}

class Authenticated extends AuthOutcome {
  Authenticated(this.account);

  final VerifiedAccount account;
}

class Rejected extends AuthOutcome {
  Rejected(this.reason);

  final String reason;
}

class DevTokenAuthenticator {
  DevTokenAuthenticator(this._config, this._accounts);

  final ServerConfig _config;
  final AccountDirectory _accounts;

  Future<AuthOutcome> authenticate(HttpHeaders headers) async {
    final presented = _bearerToken(
      headers.value(HttpHeaders.authorizationHeader),
    );
    if (presented == null) return Rejected('missing bearer token');
    if (presented != _config.devToken) return Rejected('invalid token');
    final uid = _config.devUid ?? await _accounts.soleUid();
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
