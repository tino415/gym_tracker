/// The assistants allowed to connect. Clients are matched by the `client_id`
/// string alone: the documents some of those ids point at are never fetched.
class OAuthClient {
  const OAuthClient(this.id, this.displayName, this._redirects);

  final String id;
  final String displayName;
  final List<RedirectRule> _redirects;

  bool allows(String redirectUri) =>
      _redirects.any((r) => r.matches(redirectUri));
}

sealed class RedirectRule {
  const RedirectRule();

  bool matches(String redirectUri);
}

class ExactRedirect extends RedirectRule {
  const ExactRedirect(this.uri);

  final String uri;

  @override
  bool matches(String redirectUri) => redirectUri == uri;
}

/// A native app listening on any free port of the loopback interface, so
/// scheme, host and path must match and the port is ignored.
class LoopbackRedirect extends RedirectRule {
  const LoopbackRedirect(this.host, this.path);

  final String host;
  final String path;

  @override
  bool matches(String redirectUri) {
    final uri = Uri.tryParse(redirectUri);
    return uri != null &&
        uri.scheme == 'http' &&
        uri.host == host &&
        uri.path == path &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        !uri.hasQuery;
  }
}

class ClientRegistry {
  ClientRegistry(Iterable<OAuthClient> clients)
    : _byId = {for (final c in clients) c.id: c};

  factory ClientRegistry.allowlist() => ClientRegistry(_allowlist);

  final Map<String, OAuthClient> _byId;

  OAuthClient? find(String? clientId) => _byId[clientId];

  static const _claudeAi = [
    ExactRedirect('https://claude.ai/api/mcp/auth_callback'),
  ];
  static const _chatGpt = [
    ExactRedirect('https://chatgpt.com/connector_platform_oauth_redirect'),
  ];
  static const _claudeCode = [
    LoopbackRedirect('localhost', '/callback'),
    LoopbackRedirect('127.0.0.1', '/callback'),
  ];

  static const _allowlist = [
    OAuthClient('gym-tracker-claude-ai', 'Claude', _claudeAi),
    OAuthClient(
      'https://claude.ai/oauth/mcp-oauth-client-metadata',
      'Claude',
      _claudeAi,
    ),
    OAuthClient(
      'https://claude.ai/oauth/claude-code-client-metadata',
      'Claude Code',
      _claudeCode,
    ),
    OAuthClient('gym-tracker-chatgpt', 'ChatGPT', _chatGpt),
    OAuthClient('https://chatgpt.com/oauth/client.json', 'ChatGPT', _chatGpt),
  ];
}
