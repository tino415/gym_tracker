# 1. The MCP server runs its own OAuth server, for an allowlist of clients

- **Status:** accepted, 2026-10-25
- **Applies to:** the remote MCP server (Todoist "Build the GymTracker MCP
  server", D1–D6), not yet written

## Context

GymTracker gets a remote MCP server: Dart on Cloud Run, reading `users/{uid}/…`
in Firestore, so an AI assistant can answer questions about a user's training
and later save routines. The server is on the public internet, so every call
has to carry a credential that is bound to one uid, that the assistant can keep
and renew for weeks, and that the user can take back. Firebase Auth can't
provide one: its ID tokens last an hour, only the app that signed in can renew
them, and it has no authorize endpoint for third-party clients.

The first plan targeted ChatGPT Free. Free can only use apps published in
OpenAI's directory, so the server had to accept any client that introduces
itself through CIMD or DCR, plus pass OpenAI's review. That plan leaned on
WorkOS AuthKit Standalone Connect for the authorization server.

The publication work (verification, listing pages, reviewer account, review
rounds) turned out to be too much for what it buys, and was deferred
indefinitely. The clients became Claude (claude.ai custom connectors and
Claude Code) and ChatGPT developer mode, all connecting by URL. claude.ai on
the Free plan still needs a full OAuth 2.1 handshake: discovery documents,
`/authorize`, `/token` with rotating refresh tokens, PKCE S256 and RFC 8707
`resource`. A fixed header token is a beta limited to some organizations.

## Decision

The Dart MCP server is also its own OAuth authorization server.

- **Clients are an allowlist:** claude.ai, Claude Code and ChatGPT developer
  mode, each with its redirect addresses written into the server. No general
  CIMD and no DCR. The authorization response carries `iss` (RFC 9207), so
  ChatGPT can use its fixed callback.
- **Sign-in and consent are the Flutter web route `/connect`.** `/authorize`
  redirects there with the pending request as an HMAC-signed token in the URL
  (10 minutes, same key set as the access tokens, its own `typ`), so nothing is
  stored before the user consents. The route signs the user in with Firebase,
  asks for consent on every connect, and POSTs that token, the Firebase ID
  token and the decision to the server, which checks the ID token with
  Identity Toolkit. There are no cookies, so it doesn't matter that the route
  and the server sit on different domains; the server answers CORS for the app
  origin only, and the page posts only to the server address built into the
  bundle.
- **Tokens are JWTs signed with HS256.** The secret is in Secret Manager, and a
  `kid` allows rotation. Only this server checks them. Access tokens last 1 h
  and carry `aud` = the MCP URL, `sub` = the uid, and a grant id. Refresh
  tokens last 30 d, are stored hashed, and rotate. A reused refresh token
  revokes its whole grant.
- **Revocation is by grant id** in a Firestore collection whose documents
  expire through TTL. Each instance re-reads it about once a minute.
- **A deleted or disabled account stops working because the server checks the
  uid** in Firebase Auth before each call (cached about a minute). Account
  deletion stays client-side and calls nothing new.
- **One grant covers reading and writing.** `save_routine` is annotated as a
  writing tool, so the client asks the user to confirm each call.
- All auth state lives in top-level Firestore collections (`mcpCodes`,
  `mcpRefreshTokens`, `mcpRevokedGrants`) that clients can't reach, and only
  the server touches it. That makes the runtime account a writer: it holds
  `roles/datastore.user` instead of the viewer role, and the code keeps every
  write inside those three collections.

The static token survives only as an emulator dev token. Production accepts
signed tokens alone. The privacy policy's wording for the connector ("the AI
assistant you connect, for example Claude") ships with the OAuth PR.

## Consequences

The security-critical code is ours: code expiry, PKCE, refresh rotation and
reuse detection, audience checks. It needs its own tests, and the OAuth PR is
the largest in the series (about 3–4 days). In return there is no third party
holding user identities, no extra service or runtime, the DTOs stay in Dart
only, and the whole sign-in can be exercised offline against the emulators.

A new client means a code change: adding it to the allowlist. Publishing in
ChatGPT's directory later would need general CIMD (fetching arbitrary client
documents safely, showing the client's domain on the consent screen), about a
day more.

A revocation takes up to a minute to reach every instance, and so does an
account deletion. In v1 revocation only follows a reused refresh token. There
is no "connected apps" list in the app; users disconnect in the assistant.

Whether ChatGPT Plus developer mode allows write tools is unconfirmed, and so
is whether a connector added on claude.ai web shows up on mobile.

## Alternatives considered

**WorkOS AuthKit Standalone Connect.** Our page signs the user in and tells
WorkOS the uid, and WorkOS runs OAuth, consent, CIMD/DCR and refresh. It is the
least code (about a day) and is known to work with ChatGPT and Claude. Its
value was mostly CIMD/DCR for arbitrary directory clients, which the allowlist
no longer needs. Against it: a third party holding uid and email, a WorkOS
account, and a sign-in loop that needs a WorkOS staging environment online. It
was the choice until publication was deferred.

**better-auth, self-hosted (TypeScript).** Covers every requirement through its
`oauth-provider`, `mcp` and `cimd` plugins. Rejected because it brings a
TypeScript service. Either the MCP server moves to TypeScript and duplicates
every DTO, or a second service runs beside the Dart one, with its own
database and a session cookie that would have to cross domains through a
Hosting rewrite.

**Scalekit "Bring Your Own Auth".** The same shape as WorkOS, EU-hosted, with
custom scopes, at roughly $99–198 a month. Neither EU storage nor custom
scopes turned out to matter.

**A personal secret URL, no OAuth.** About half a day of work. Undocumented
for claude.ai, against Anthropic's guidance for static credentials, hit by an
open bug for connectors without sign-in (claude-ai-mcp#697), and the URL is a
password that never expires.

**Ory Hydra, Auth0, Stytch, Descope, Logto, Zitadel, Supabase, Keycloak.**
Either no RFC 8707 or CIMD support, or the users would have to move out of
Firebase Auth. No Firebase- or Google-native authorization server for MCP
exists.

**Allowlist plus general CIMD, or plus DCR.** Any client could connect, at
about one or two extra days and a larger attack surface (fetching strangers'
URLs, a public registration endpoint). Not needed for the clients in use.

**Opaque tokens looked up per call** instead of JWTs. They give immediate
revocation and no signing key, but JWTs plus a short-lived revocation list
were preferred.
