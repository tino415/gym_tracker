# Deploying the MCP server

The server runs on Cloud Run in the app's Firebase project (ADR 0001), in the
region `GCP_REGION` names, next to the Firestore database. The image is built and
deployed by `.github/workflows/mcp-deploy.yml`, because Cloud Run is amd64
only and `dart build cli` cannot cross-compile. Nothing is deployed from a
workstation and no service-account key exists for it: GitHub Actions signs in
through Workload Identity Federation.

Assistants sign in with OAuth 2.1; the server is its own authorization server
and the web app's `/connect` page is where a user says yes. There is no static
token in production.

## Infrastructure

The cloud resources are defined outside this repository. The runtime service
account bypasses `firestore.rules`: it reads users' data and writes only the
sign-in state in `mcpCodes`, `mcpRefreshTokens` and `mcpRevokedGrants`, whose
documents a TTL policy on `expiresAt` removes.

Those definitions supply everything the deploy workflow reads:

| Where | Name | What it is |
|---|---|---|
| Actions variables | `GCP_PROJECT`, `GCP_PROJECT_NUMBER`, `GCP_REGION` | where the service runs, and its URL |
| Actions variables | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOYER` | how the workflow signs in to Google Cloud |
| Secret Manager | `mcp-signing-keys` | JSON `{kid: secret}` of HS256 keys, read by Cloud Run; the workflow names the current one in `MCP_SIGNING_KID` |

The Actions values are variables, not secrets: none of them grants access on
its own. To rotate the signing key, add a second kid to `mcp-signing-keys`,
deploy with `MCP_SIGNING_KID` pointing at it, and drop the old kid after an
hour (the access token lifetime) plus the 10 minutes a pending request lives.

Each deploy replaces the service's env vars and secrets with the workflow's
lists: a name dropped from the workflow, or a value set by hand in the
console, is gone after the next deploy.

The deploy sets `MCP_PUBLIC_URL` (the Cloud Run URL, also the issuer),
`MCP_APP_URL` (the origin that serves `/connect`) and `MCP_FIREBASE_API_KEY`
(the public web key, which Identity Toolkit asks for when it checks a sign-in).
The web app is built with `MCP_SERVER_URL=<url without /mcp> just deploy`, so
its consent page posts only to that server.

## Deploying

Actions → MCP deploy → Run workflow, on `main`, or from any checkout:

```bash
gh workflow run mcp-deploy.yml --ref main
```

It refuses a commit whose `ci.yml` push run did not pass. The run summary
lists the secrets the service mounts, only `MCP_SIGNING_KEYS=mcp-signing-keys`,
and shows the URL, `<url>` below.

## Checking it

```bash
just mcp-smoke <url>
```

checks the 401 challenge and both metadata documents. Then connect a client,
which opens the browser on the web app's consent page:

```bash
claude mcp add --transport http gym <url>
```

On claude.ai add a custom connector with the same URL; ChatGPT developer mode
takes it too. A grant ends when the user removes GymTracker in the assistant
(access stops within an hour), or after 30 days unused.
