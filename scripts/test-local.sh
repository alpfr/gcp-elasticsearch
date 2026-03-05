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
