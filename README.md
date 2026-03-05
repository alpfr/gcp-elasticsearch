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
