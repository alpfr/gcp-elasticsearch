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
