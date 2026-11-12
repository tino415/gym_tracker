# Deploying the MCP server

The server runs on Cloud Run in the app's Firebase project (ADR 0001), in the
region `GCP_REGION` names, next to the Firestore database. The image is built and
deployed by `.github/workflows/mcp-deploy.yml`, because Cloud Run is amd64
only and `dart build cli` cannot cross-compile. Nothing is deployed from a
workstation and no service-account key exists for it: GitHub Actions signs in
through Workload Identity Federation.

Until OAuth lands the server accepts one personal token, mapped to one uid.

## Infrastructure

The cloud resources are defined outside this repository. The runtime service
account bypasses `firestore.rules`, so it can only read.

Those definitions supply everything the deploy workflow reads:

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
shows the URL, `<url>` below.

## Checking it

```bash
MCP_TOKEN=<token> just mcp-smoke <url>
```

lists the tools and your routines. Then connect a client:

```bash
claude mcp add --transport http gym <url> \
  --header "Authorization: Bearer <token>"
```

On claude.ai a custom connector works only if its dialog shows the Request
headers section: No sign-in, `Authorization: Bearer <token>`. ChatGPT has no
header option and waits for OAuth.
