#!/bin/bash
# setup.sh - Create project directory structure and initial files for Cloud Run + Elasticsearch

set -e  # Exit on error

echo "Creating project directory structure..."

# Create directories
mkdir -p src utils tests/unit tests/integration config scripts terraform/modules/elasticsearch

# Create __init__.py files
touch src/__init__.py utils/__init__.py tests/__init__.py tests/unit/__init__.py tests/integration/__init__.py

# ==============================================
# src/app.py - Main Flask application
# ==============================================
cat > src/app.py << 'EOF'
import os
import logging
from flask import Flask, request, jsonify
from elasticsearch import Elasticsearch, helpers
from google.cloud import secretmanager
import json

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

def get_secret(secret_name):
    """Retrieve secret from Secret Manager"""
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{os.environ.get('PROJECT_ID')}/secrets/{secret_name}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")

class ElasticsearchClient:
    def __init__(self):
        self.project_id = os.environ.get('PROJECT_ID')
        self.cloud_id = get_secret('elastic-cloud-id')
        self.password = get_secret('elastic-password')
        self.username = 'elastic'
        self.client = None
        self.connect()

    def connect(self):
        try:
            self.client = Elasticsearch(
                cloud_id=self.cloud_id,
                basic_auth=(self.username, self.password),
                request_timeout=30,
                max_retries=3,
                retry_on_timeout=True
            )
            info = self.client.info()
            app.logger.info(f"✅ Connected to Elasticsearch: {info['version']['number']}")
        except Exception as e:
            app.logger.error(f"❌ Connection failed: {e}")
            self.client = None

    def search(self, index, query):
        if not self.client:
            return {"error": "Elasticsearch not connected"}
        try:
            return self.client.search(index=index, body=query)
        except Exception as e:
            app.logger.error(f"Search error: {e}")
            return {"error": str(e)}

    def index_document(self, index, document, doc_id=None):
        try:
            return self.client.index(index=index, document=document, id=doc_id)
        except Exception as e:
            app.logger.error(f"Indexing error: {e}")
            return {"error": str(e)}

    def bulk_index(self, index, documents):
        try:
            actions = [{"_index": index, "_source": doc} for doc in documents]
            success, failed = helpers.bulk(self.client, actions, stats_only=True)
            return {"success": success, "failed": failed}
        except Exception as e:
            app.logger.error(f"Bulk indexing error: {e}")
            return {"error": str(e)}

es_client = ElasticsearchClient()

@app.route('/search', methods=['POST'])
def search():
    data = request.json
    if not data or 'query' not in data:
        return jsonify({"error": "Missing query"}), 400
    result = es_client.search(
        index=data.get('index', 'my-index'),
        query=data['query']
    )
    if "error" in result:
        return jsonify(result), 500
    return jsonify(result), 200

@app.route('/index', methods=['POST'])
def index_document():
    data = request.json
    if not data or 'document' not in data:
        return jsonify({"error": "Missing document"}), 400
    result = es_client.index_document(
        index=data.get('index', 'my-index'),
        document=data['document'],
        doc_id=data.get('id')
    )
    if "error" in result:
        return jsonify(result), 500
    return jsonify(result), 201

@app.route('/health', methods=['GET'])
def health():
    if es_client.client and es_client.client.ping():
        return jsonify({"status": "healthy", "elasticsearch": "connected"}), 200
    return jsonify({"status": "degraded", "elasticsearch": "disconnected"}), 503

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)
EOF

# ==============================================
# tests/unit/test_app.py
# ==============================================
cat > tests/unit/test_app.py << 'EOF'
import pytest
from src.app import app

@pytest.fixture
def client():
    with app.test_client() as client:
        yield client

def test_health_endpoint(client):
    response = client.get('/health')
    # Since Elasticsearch is not connected in tests, we expect degraded
    assert response.status_code == 503
    assert response.json['status'] == 'degraded'
EOF

# ==============================================
# tests/integration/test_api.py
# ==============================================
cat > tests/integration/test_api.py << 'EOF'
import pytest
import requests
import os

@pytest.fixture
def service_url():
    # Use environment variable or default to localhost
    return os.environ.get('SERVICE_URL', 'http://localhost:8080')

def test_health(service_url):
    response = requests.get(f"{service_url}/health")
    assert response.status_code in (200, 503)  # Could be healthy or degraded
    assert 'status' in response.json()

def test_index_and_search(service_url):
    # Index a test document
    doc = {
        "index": "test-integration",
        "document": {
            "title": "Integration Test",
            "content": "This is a test document"
        }
    }
    index_resp = requests.post(f"{service_url}/index", json=doc)
    assert index_resp.status_code == 201

    # Search for it
    search_query = {
        "index": "test-integration",
        "query": {
            "query": {
                "match": {
                    "content": "test"
                }
            }
        }
    }
    search_resp = requests.post(f"{service_url}/search", json=search_query)
    assert search_resp.status_code == 200
    data = search_resp.json()
    assert data['hits']['total']['value'] > 0
EOF

# ==============================================
# config/env.yaml
# ==============================================
cat > config/env.yaml << 'EOF'
# Environment variables for local development
PROJECT_ID: your-project-id
# Do NOT store secrets here; use Secret Manager
EOF

# ==============================================
# scripts/deploy.sh
# ==============================================
cat > scripts/deploy.sh << 'EOF'
#!/bin/bash
# scripts/deploy.sh - Deploy to Cloud Run

set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-us-central1}
SERVICE_NAME=${SERVICE_NAME:-elastic-app}
IMAGE_NAME="${REGION}-docker.pkg.dev/${PROJECT_ID}/elastic-app-repo/elastic-app:latest"

echo "Deploying ${SERVICE_NAME} to Cloud Run in ${REGION}..."

gcloud run deploy ${SERVICE_NAME} \
  --image=${IMAGE_NAME} \
  --region=${REGION} \
  --platform=managed \
  --allow-unauthenticated \
  --memory=1Gi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID}" \
  --update-secrets=elastic-cloud-id=elastic-cloud-id:latest,elastic-password=elastic-password:latest

echo "Deployment complete."
EOF
chmod +x scripts/deploy.sh

# ==============================================
# scripts/setup-secrets.sh
# ==============================================
cat > scripts/setup-secrets.sh << 'EOF'
#!/bin/bash
# scripts/setup-secrets.sh - Store secrets in Secret Manager

set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
SERVICE_ACCOUNT="cloud-run-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Setting up secrets for project ${PROJECT_ID}"

# Prompt for Elasticsearch Cloud ID and password
read -p "Enter Elasticsearch Cloud ID: " CLOUD_ID
read -sp "Enter Elasticsearch password: " ES_PASSWORD
echo ""

# Create secrets
echo -n "$CLOUD_ID" | gcloud secrets create elastic-cloud-id \
  --project=$PROJECT_ID \
  --replication-policy="automatic" \
  --data-file=-

echo -n "$ES_PASSWORD" | gcloud secrets create elastic-password \
  --project=$PROJECT_ID \
  --replication-policy="automatic" \
  --data-file=-

# Grant service account access
gcloud secrets add-iam-policy-binding elastic-cloud-id \
  --project=$PROJECT_ID \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding elastic-password \
  --project=$PROJECT_ID \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

echo "Secrets created and permissions granted."
EOF
chmod +x scripts/setup-secrets.sh

# ==============================================
# scripts/test-local.sh
# ==============================================
cat > scripts/test-local.sh << 'EOF'
#!/bin/bash
# scripts/test-local.sh - Run tests locally (requires Elasticsearch accessible)

set -e

# Start a local Elasticsearch container for integration tests if desired
# docker run -d -p 9200:9200 -e "discovery.type=single-node" docker.elastic.co/elasticsearch/elasticsearch:8.12.0

# Install test dependencies
pip install -r requirements-dev.txt

# Run unit tests
pytest tests/unit -v

# Run integration tests (assumes Elasticsearch is running at localhost:9200)
# Set environment variables as needed
export SERVICE_URL=http://localhost:8080
pytest tests/integration -v
EOF
chmod +x scripts/test-local.sh

# ==============================================
# terraform/main.tf (basic setup)
# ==============================================
cat > terraform/main.tf << 'EOF'
provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "run" {
  service = "run.googleapis.com"
}

resource "google_project_service" "secretmanager" {
  service = "secretmanager.googleapis.com"
}

resource "google_project_service" "artifactregistry" {
  service = "artifactregistry.googleapis.com"
}

resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "elastic-app-repo"
  description   = "Docker repository for Elasticsearch app"
  format        = "DOCKER"
}

resource "google_service_account" "cloud_run_sa" {
  account_id   = "cloud-run-sa"
  display_name = "Cloud Run Service Account"
}

# Outputs
output "service_account_email" {
  value = google_service_account.cloud_run_sa.email
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/elastic-app-repo"
}
EOF

cat > terraform/variables.tf << 'EOF'
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}
EOF

cat > terraform/outputs.tf << 'EOF'
output "service_account_email" {
  value = google_service_account.cloud_run_sa.email
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/elastic-app-repo"
}
EOF

# ==============================================
# cloudbuild.yaml
# ==============================================
cat > cloudbuild.yaml << 'EOF'
steps:
  # Unit tests
  - name: 'python:3.11-slim'
    id: 'unit-tests'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        pip install pytest pytest-cov
        pytest tests/unit --cov=src --cov-report=xml
    waitFor: ['-']

  # Build Docker image
  - name: 'gcr.io/cloud-builders/docker'
    id: 'build'
    args:
      - 'build'
      - '-t'
      - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPOSITORY}/elastic-app:${COMMIT_SHA}'
      - '--cache-from'
      - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPOSITORY}/elastic-app:latest'
      - '.'

  # Push to Artifact Registry
  - name: 'gcr.io/cloud-builders/docker'
    id: 'push'
    args:
      - 'push'
      - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPOSITORY}/elastic-app:${COMMIT_SHA}'

  # Deploy to Cloud Run
  - name: 'gcr.io/cloud-builders/gcloud'
    id: 'deploy'
    args:
      - 'run'
      - 'deploy'
      - '${_SERVICE_NAME}'
      - '--image=${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPOSITORY}/elastic-app:${COMMIT_SHA}'
      - '--region=${_REGION}'
      - '--platform=managed'
      - '--allow-unauthenticated'
      - '--memory=1Gi'
      - '--cpu=1'
      - '--min-instances=0'
      - '--max-instances=10'
      - '--set-env-vars=PROJECT_ID=${PROJECT_ID}'
      - '--update-secrets=elastic-cloud-id=elastic-cloud-id:latest,elastic-password=elastic-password:latest'
      - '--service-account=${_SERVICE_ACCOUNT}'

  # Smoke test
  - name: 'curlimages/curl'
    id: 'smoke-test'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        URL=$(gcloud run services describe ${_SERVICE_NAME} --region=${_REGION} --format='value(status.url)')
        curl -f -s $URL/health | grep -q "healthy" || exit 1

substitutions:
  _SERVICE_NAME: elastic-app
  _REGION: us-central1
  _REPOSITORY: elastic-app-repo
  _SERVICE_ACCOUNT: cloud-run-sa@${PROJECT_ID}.iam.gserviceaccount.com

images:
  - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPOSITORY}/elastic-app:${COMMIT_SHA}'

options:
  logging: CLOUD_LOGGING_ONLY
  machineType: 'E2_HIGHCPU_8'

timeout: 1800s
EOF

# ==============================================
# Dockerfile
# ==============================================
cat > Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY src/ ./src/
COPY utils/ ./utils/

# Create non-root user
RUN addgroup --system app && adduser --system --group app
USER app

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8080/health', timeout=2)" || exit 1

# Run the application
CMD ["python", "src/app.py"]

EXPOSE 8080
EOF

# ==============================================
# requirements.txt
# ==============================================
cat > requirements.txt << 'EOF'
flask==3.0.0
elasticsearch==8.12.0
google-cloud-secret-manager==2.19.0
gunicorn==21.2.0
EOF

# ==============================================
# requirements-dev.txt (for testing)
# ==============================================
cat > requirements-dev.txt << 'EOF'
pytest==8.0.0
pytest-cov==4.1.0
requests==2.31.0
EOF

# ==============================================
# .dockerignore
# ==============================================
cat > .dockerignore << 'EOF'
.git
__pycache__
*.pyc
.env
.venv
tests/
scripts/
terraform/
config/
README.md
requirements-dev.txt
EOF

# ==============================================
# .gitignore
# ==============================================
cat > .gitignore << 'EOF'
# Python
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
env/
venv/
.env
*.egg-info/
dist/
build/

# IDE
.vscode/
.idea/
*.swp

# Local config
config/local.yaml

# Terraform
terraform/.terraform/
terraform/terraform.tfstate*
terraform/*.tfplan

# Secrets
**/secrets/
*.pem
*.key
EOF

# ==============================================
# README.md
# ==============================================
cat > README.md << 'EOF'
# Cloud Run + Elasticsearch Application

This project demonstrates a Flask application running on Cloud Run that connects to Elasticsearch (Elastic Cloud). It provides REST endpoints for indexing and searching documents.

## Prerequisites

- Google Cloud Project with billing enabled
- gcloud CLI installed and configured
- Elasticsearch deployment (Elastic Cloud recommended)

## Setup

1. **Enable APIs**
   ```bash
   gcloud services enable run.googleapis.com secretmanager.googleapis.com artifactregistry.googleapis.com
