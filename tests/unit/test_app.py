import pytest
from unittest.mock import patch


@pytest.fixture
def client():
    # Patch Secret Manager so import doesn't require GCP credentials
    with patch("src.app.get_secret", return_value="mock-value"):
        from src.app import app
        with app.test_client() as client:
            yield client


def test_health_endpoint_degraded(client):
    """Health returns 503 when ES is not connected."""
    response = client.get("/health")
    assert response.status_code == 503
    assert response.json["status"] == "degraded"


def test_search_missing_query(client):
    """Search returns 400 when query is missing."""
    response = client.post("/search", json={})
    assert response.status_code == 400
    assert "error" in response.json


def test_index_missing_document(client):
    """Index returns 400 when document is missing."""
    response = client.post("/index", json={})
    assert response.status_code == 400
    assert "error" in response.json


def test_bulk_missing_documents(client):
    """Bulk returns 400 when documents is missing."""
    response = client.post("/bulk", json={})
    assert response.status_code == 400
    assert "error" in response.json
