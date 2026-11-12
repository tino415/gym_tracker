# Deploying the MCP server

The server runs on Cloud Run in `gym-tracker-44a5f` (ADR 0001), in
`us-central1`, next to the Firestore database (`nam5`). The image is built and
deployed by `.github/workflows/mcp-deploy.yml`, because Cloud Run is amd64
only and `dart build cli` cannot cross-compile. Nothing is deployed from a
workstation and no service-account key exists for it: GitHub Actions signs in
through Workload Identity Federation.

Until OAuth lands (D5) the server accepts one personal token, mapped to one uid.

## Infrastructure

The cloud resources are defined in OpenTofu outside this repository: the APIs,
the Artifact Registry repository, the runtime service account (read-only until
D6: it bypasses `firestore.rules`), the deployer service account and the
Workload Identity pool it is reached through, the two secrets, and a 5-unit
budget with alerts at 50, 90 and 100 %. Cloud Run needs the Blaze plan first.

The same definitions supply everything the deploy workflow reads:

| Where | Name | What it is |
|---|---|---|
| Actions variables | `GCP_PROJECT`, `GCP_PROJECT_NUMBER`, `GCP_REGION` | where the service runs, and its URL |
| Actions variables | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOYER` | how the workflow signs in to Google Cloud |
| Secret Manager | `mcp-personal-token`, `mcp-personal-uid` | the personal token and the uid it maps to, read by Cloud Run |

The Actions values are variables, not secrets: none of them grants access on
its own. The token is generated with the secret, and the value stored in
`mcp-personal-token` is the one clients send.

## Deploying

Actions → MCP deploy → Run workflow, on `main`, or from any checkout:

```bash
gh workflow run mcp-deploy.yml --ref main
```

It refuses a commit whose `ci.yml` push run did not pass. The run summary
shows the URL: `https://gym-tracker-mcp-<number>.us-central1.run.app/mcp`.

## Checking it

```bash
MCP_TOKEN=<token> just mcp-smoke https://gym-tracker-mcp-<number>.us-central1.run.app/mcp
```

lists the five tools and your routines. Then connect a client:

```bash
claude mcp add --transport http gym https://gym-tracker-mcp-<number>.us-central1.run.app/mcp \
  --header "Authorization: Bearer <token>"
```

On claude.ai a custom connector works only if its dialog shows the Request
headers section: No sign-in, `Authorization: Bearer <token>`. ChatGPT has no
header option and waits for OAuth.
