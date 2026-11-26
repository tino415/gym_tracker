# MCP server

`mcp_server/` is a plain Dart package (mcp_dart, Streamable HTTP) that lets an AI
assistant read a user's data in Firestore; ADR 0001 records how it is
authenticated. It reads the app's DTOs through a path dependency on this
package, so it resolves with `flutter pub get`, and `flutter analyze` at the
root skips it. `just mcp` runs it against the emulators from `just up` (also a
process-compose entry); on the emulators the static dev token is `dev-token`
unless `MCP_DEV_TOKEN` says otherwise, and it maps to `MCP_DEV_UID` or the
emulator's only account.

Assistants sign in with OAuth 2.1, the server being its own authorization
server (ADR 0001): `/authorize` sends the browser to the web app's `/connect`
page with an HMAC-signed pending request (nothing is stored before consent),
the page POSTs the user's decision and Firebase ID token to `/connect`, and
`/token` exchanges the code (PKCE S256, single use) for a one-hour HS256 access
token and a rotating 30-day refresh token. Clients are an allowlist by
`client_id`, nothing is fetched. Codes, refresh tokens (hashed) and revoked
grants live in top-level Firestore collections with a TTL on `expiresAt`, so
the runtime account can write there; a reused code or refresh token revokes its
grant. The web build must be given `MCP_SERVER_URL` (the recipes do).

The emulator host variables pick the mode. Without them the server reads
production through Application Default Credentials and refuses to start unless
`GOOGLE_CLOUD_PROJECT`, `MCP_SIGNING_KEYS` (JSON `{kid: secret}`, secrets 32+
characters), `MCP_SIGNING_KID`, `MCP_PUBLIC_URL`, `MCP_APP_URL`,
`MCP_FIREBASE_API_KEY` and `MCP_ALLOWED_HOSTS` are all set; the dev token is
never read there. `MCP_ALLOWED_HOSTS` must name the public hostname, or the
DNS-rebinding guard answers every request with a 403. A token is checked, and
the budgets (`RequestBudget`: 60 a minute and 1000 a day per user, 300 and
10000 for everyone, 30 and 1000 for `/connect` plus `/token`) spent, before any
Google call, so a flood costs no Firestore read. Deploying is
`docs/mcp-deploy.md`.

`just mcp-test` runs the package's tests on throwaway emulators (`firebase
emulators:exec`), so stop `just up` first: same ports. CI runs it too. `just
mcp-smoke [url]` checks the 401 challenge and both metadata documents with
curl, then walks initialize → tools/list → `list_routines` with `MCP_TOKEN`
(or the dev token on loopback). `just mcp-bundle` builds the native bundle that
`mcp_server/Containerfile` packages, for the host's architecture only, which is
why the Cloud Run image is built in GitHub Actions.

Read tools: `list_routines`, `get_routine`, `list_workouts`, `get_workout`,
`find_exercises`. Workout reads name their fields (the heart-rate series is about
680 samples inline) and pass through `stripHealthData` (now in
`lib/sync/health_data.dart`, re-exported by `health_upload_consent.dart`): there
is no heart-rate scope in v1, so no tool may return one.

A tool never takes a uid. The only route to `users/{uid}/…` is `UserScope`,
which needs a `VerifiedAccount` from `AccountDirectory.verify` (Firebase Auth,
cached a minute). `GymMcpServer` owns the session map instead of using
`StreamableMcpServer`, because there a tool can't learn which user a request
belongs to.
