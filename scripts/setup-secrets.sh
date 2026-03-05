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
