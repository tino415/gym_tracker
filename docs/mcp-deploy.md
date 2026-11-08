# Deploying the MCP server

The server runs on Cloud Run in `gym-tracker-44a5f` (ADR 0001). The image is
built and deployed by `.github/workflows/mcp-deploy.yml`, because Cloud Run is
amd64 only and `dart build cli` cannot cross-compile. Nothing is deployed
from a workstation and no service-account key exists anywhere: GitHub Actions
signs in through Workload Identity Federation.

Until OAuth lands (D5) the server accepts one personal token, mapped to one uid.

## One-time setup

Cloud Run needs the Blaze plan. Everything below runs in Cloud Shell in the
console, with the project selected. Pick the region next to the Firestore
location (Firestore → Databases shows it).

```bash
PROJECT=gym-tracker-44a5f
REGION=europe-west1          # next to the Firestore location
REPO=tino415/gym_tracker
NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
RUNTIME=gym-tracker-mcp@$PROJECT.iam.gserviceaccount.com
DEPLOYER=gym-tracker-mcp-deployer@$PROJECT.iam.gserviceaccount.com

gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com iamcredentials.googleapis.com

gcloud artifacts repositories create gym-tracker \
  --repository-format=docker --location=$REGION

# Read-only until save_routine (D6). It bypasses firestore.rules.
gcloud iam service-accounts create gym-tracker-mcp
gcloud projects add-iam-policy-binding $PROJECT \
  --member=serviceAccount:$RUNTIME --role=roles/datastore.viewer
gcloud projects add-iam-policy-binding $PROJECT \
  --member=serviceAccount:$RUNTIME --role=roles/firebaseauth.viewer

gcloud iam service-accounts create gym-tracker-mcp-deployer
for role in roles/run.admin roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding $PROJECT \
    --member=serviceAccount:$DEPLOYER --role=$role
done
gcloud iam service-accounts add-iam-policy-binding $RUNTIME \
  --member=serviceAccount:$DEPLOYER --role=roles/iam.serviceAccountUser

gcloud iam workload-identity-pools create github --location=global
gcloud iam workload-identity-pools providers create-oidc github \
  --location=global --workload-identity-pool=github \
  --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping=google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref \
  --attribute-condition="assertion.repository == '$REPO' && assertion.ref == 'refs/heads/main'"
gcloud iam service-accounts add-iam-policy-binding $DEPLOYER \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/$REPO"

# The token: at least 32 characters. Keep a copy for the clients.
openssl rand -hex 32 | tr -d '\n' | gcloud secrets create mcp-personal-token --data-file=-
printf '%s' '<your uid from Authentication → Users>' | gcloud secrets create mcp-personal-uid --data-file=-
for secret in mcp-personal-token mcp-personal-uid; do
  gcloud secrets add-iam-policy-binding $secret \
    --member=serviceAccount:$RUNTIME --role=roles/secretmanager.secretAccessor
done

echo "GCP_PROJECT=$PROJECT GCP_PROJECT_NUMBER=$NUMBER GCP_REGION=$REGION"
echo "GCP_WORKLOAD_IDENTITY_PROVIDER=projects/$NUMBER/locations/global/workloadIdentityPools/github/providers/github"
echo "GCP_DEPLOYER=$DEPLOYER"
```

Put the five printed values into the repository's Actions **variables** (not
secrets): Settings → Secrets and variables → Actions → Variables.

### Cost caps

`max-instances=1` bounds compute, and the server's request budget (60 a minute,
1000 a day per token, checked before any Google call) bounds Firestore reads.
Add the backstop in the console:

- Billing → Budgets & alerts: a budget on the project, with e-mail alerts.
- Connect the budget to a Pub/Sub topic and a function that disables billing,
  as in [Disable billing usage with
  notifications](https://cloud.google.com/billing/docs/how-to/disable-billing-with-notifications).
  Budget data lags by hours, so this caps a runaway, not a spike.

## Deploying

Actions → MCP deploy → Run workflow, on `main`, or from any checkout:

```bash
gh workflow run mcp-deploy.yml --ref main
```

It refuses a commit whose `ci.yml` push run did not pass. The run summary
shows the URL: `https://gym-tracker-mcp-<number>.<region>.run.app/mcp`.

## Checking it

```bash
MCP_TOKEN=<token> dev-run just mcp-smoke https://gym-tracker-mcp-<number>.<region>.run.app/mcp
```

lists the five tools and your routines. Then connect a client:

```bash
claude mcp add --transport http gym https://gym-tracker-mcp-<number>.<region>.run.app/mcp \
  --header "Authorization: Bearer <token>"
```

On claude.ai a custom connector works only if its dialog shows the Request
headers section: No sign-in, `Authorization: Bearer <token>`. ChatGPT has no
header option and waits for OAuth.
