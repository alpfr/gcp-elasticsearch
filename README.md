# Elasticsearch API on GCP Cloud Run

A serverless REST API that provides document indexing and search capabilities via Elasticsearch (Elastic Cloud), deployed on Google Cloud Run.

**Live URL:** `https://elastic-app-200624997525.us-central1.run.app`

## Architecture

```
Client --> Cloud Run (Flask + Gunicorn) --> Elastic Cloud
                |
                v
         Secret Manager
      (cloud-id, password)
```

### Design Decisions

- **Gunicorn** with 1 worker and 4 threads -- optimized for Cloud Run's single-vCPU allocation
- **Multi-stage Docker build** -- build tools (gcc) stay in the builder stage, keeping the runtime image slim
- **Lazy Elasticsearch initialization** -- connection is established on the first request, not at import time, reducing cold start latency
- **Singleton Secret Manager client** -- reused across secret fetches to avoid repeated client instantiation
- **Structured JSON logging** -- Cloud Run Log Explorer parses severity levels natively
- **Non-root container** -- runs as `app` user for security
- **Scales to zero** -- no cost when idle, with min-instances=0 and max-instances=10

### GCP Services Used

| Service | Purpose |
|---------|---------|
| Cloud Run | Serverless container hosting |
| Secret Manager | Stores Elasticsearch credentials |
| Artifact Registry | Docker image repository |
| Cloud Build | CI/CD pipeline (optional) |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | List all available endpoints |
| `GET` | `/health` | Health check (returns ES connection status) |
| `POST` | `/search` | Search documents in an index |
| `POST` | `/index` | Index a single document |
| `POST` | `/bulk` | Bulk index multiple documents |

### Request Examples

**Search documents:**
```bash
curl -X POST https://elastic-app-200624997525.us-central1.run.app/search \
  -H "Content-Type: application/json" \
  -d '{
    "index": "my-index",
    "query": {
      "query": {
        "match": { "content": "search term" }
      }
    }
  }'
```

**Index a document:**
```bash
curl -X POST https://elastic-app-200624997525.us-central1.run.app/index \
  -H "Content-Type: application/json" \
  -d '{
    "index": "my-index",
    "document": { "title": "Doc Title", "content": "Document body" },
    "id": "optional-doc-id"
  }'
```

**Bulk index:**
```bash
curl -X POST https://elastic-app-200624997525.us-central1.run.app/bulk \
  -H "Content-Type: application/json" \
  -d '{
    "index": "my-index",
    "documents": [
      { "title": "Doc 1", "content": "First" },
      { "title": "Doc 2", "content": "Second" }
    ]
  }'
```

## Project Structure

```
.
├── src/
│   ├── __init__.py
│   └── app.py                  # Flask application + ES client
├── tests/
│   ├── unit/
│   │   └── test_app.py         # Unit tests (mocked ES)
│   └── integration/
│       └── test_api.py         # Integration tests (live service)
├── terraform/
│   ├── main.tf                 # GCP infrastructure (APIs, AR, SA, IAM)
│   ├── variables.tf            # Project ID, region
│   └── outputs.tf              # SA email, AR repo path
├── scripts/
│   ├── deploy.sh               # Manual Cloud Run deployment
│   ├── setup-secrets.sh        # Store ES credentials in Secret Manager
│   └── test-local.sh           # Run tests locally
├── config/
│   └── env.yaml                # Environment variable template
├── Dockerfile                  # Multi-stage build (builder + runtime)
├── cloudbuild.yaml             # Cloud Build CI/CD pipeline
├── requirements.txt            # Production dependencies
└── requirements-dev.txt        # Test dependencies
```

## Prerequisites

- Google Cloud project with billing enabled
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated
- Docker installed
- Elasticsearch deployment ([Elastic Cloud](https://cloud.elastic.co) recommended)

## Deployment Guide

### 1. Configure GCP Project

```bash
export PROJECT_ID=your-project-id
export REGION=us-central1

gcloud config set project $PROJECT_ID
```

### 2. Provision Infrastructure (Terraform)

```bash
cd terraform
terraform init
terraform plan -var="project_id=$PROJECT_ID"
terraform apply -var="project_id=$PROJECT_ID"
```

This creates:
- Artifact Registry repository (`elastic-app-repo`)
- Cloud Run service account (`cloud-run-sa`) with Secret Manager access
- Enables required GCP APIs

### 3. Store Elasticsearch Credentials

```bash
# Interactive -- prompts for Cloud ID and password
./scripts/setup-secrets.sh
```

Or manually:
```bash
echo -n "YOUR_CLOUD_ID" | gcloud secrets create elastic-cloud-id \
  --project=$PROJECT_ID --replication-policy="automatic" --data-file=-

echo -n "YOUR_PASSWORD" | gcloud secrets create elastic-password \
  --project=$PROJECT_ID --replication-policy="automatic" --data-file=-
```

### 4. Build and Push Docker Image

```bash
# Configure Docker for Artifact Registry
gcloud auth configure-docker ${REGION}-docker.pkg.dev

# Build for amd64 (required for Cloud Run, even on Apple Silicon Macs)
docker build --platform linux/amd64 \
  -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/elastic-app-repo/elastic-app:latest .

# Push
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/elastic-app-repo/elastic-app:latest
```

### 5. Deploy to Cloud Run

```bash
./scripts/deploy.sh
```

Or manually:
```bash
gcloud run deploy elastic-app \
  --image=${REGION}-docker.pkg.dev/${PROJECT_ID}/elastic-app-repo/elastic-app:latest \
  --region=${REGION} \
  --platform=managed \
  --allow-unauthenticated \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --concurrency=80 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID}" \
  --update-secrets=elastic-cloud-id=elastic-cloud-id:latest,elastic-password=elastic-password:latest \
  --service-account=cloud-run-sa@${PROJECT_ID}.iam.gserviceaccount.com
```

### 6. Verify

```bash
# Get service URL
SERVICE_URL=$(gcloud run services describe elastic-app \
  --region=$REGION --format='value(status.url)')

# Health check
curl $SERVICE_URL/health
```

## CI/CD with Cloud Build

The `cloudbuild.yaml` pipeline runs automatically on push:

1. **Unit tests** -- runs pytest with coverage
2. **Build** -- Docker image with layer caching
3. **Push** -- to Artifact Registry (`:latest` and `:$COMMIT_SHA` tags)
4. **Deploy** -- to Cloud Run
5. **Smoke test** -- verifies `/health` endpoint responds

Trigger setup:
```bash
gcloud builds triggers create github \
  --repo-name=gcp-elasticsearch \
  --repo-owner=alpfr \
  --branch-pattern="^main$" \
  --build-config=cloudbuild.yaml
```

## Updating Secrets

To rotate Elasticsearch credentials without redeploying:

```bash
# Add a new version of the secret
echo -n "NEW_PASSWORD" | gcloud secrets versions add elastic-password --data-file=-

# Force Cloud Run to pick up the new secret (triggers new revision)
gcloud run services update elastic-app --region=$REGION \
  --update-secrets=elastic-password=elastic-password:latest
```

## Local Development

```bash
# Install dependencies
pip install -r requirements.txt -r requirements-dev.txt

# Run unit tests (no GCP credentials needed)
pytest tests/unit -v

# Run locally (requires GCP credentials + PROJECT_ID)
export PROJECT_ID=your-project-id
python src/app.py
```

## Cloud Run Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| Memory | 512Mi | Sufficient for a lightweight API proxy |
| CPU | 1 | Single vCPU; Gunicorn uses threads, not processes |
| Min instances | 0 | Scale to zero when idle to minimize cost |
| Max instances | 10 | Limits concurrent containers |
| Concurrency | 80 | Requests per container before scaling |
| Timeout | 120s | Gunicorn timeout for long-running ES queries |
