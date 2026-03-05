#!/bin/bash
# scripts/deploy.sh - Deploy to Cloud Run

set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-us-central1}
SERVICE_NAME=${SERVICE_NAME:-elastic-app}
SERVICE_ACCOUNT="cloud-run-sa@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_NAME="${REGION}-docker.pkg.dev/${PROJECT_ID}/elastic-app-repo/elastic-app:latest"

echo "Deploying ${SERVICE_NAME} to Cloud Run in ${REGION}..."

gcloud run deploy "${SERVICE_NAME}" \
  --image="${IMAGE_NAME}" \
  --region="${REGION}" \
  --platform=managed \
  --allow-unauthenticated \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --concurrency=80 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID}" \
  --update-secrets=elastic-cloud-id=elastic-cloud-id:latest,elastic-password=elastic-password:latest \
  --service-account="${SERVICE_ACCOUNT}"

echo "Deployment complete."
echo "Service URL: $(gcloud run services describe "${SERVICE_NAME}" --region="${REGION}" --format='value(status.url)')"
