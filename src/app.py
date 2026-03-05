import os
import logging

from flask import Flask, request, jsonify
from elasticsearch import Elasticsearch, helpers
from google.cloud import secretmanager

app = Flask(__name__)

# Structured JSON logging for Cloud Run
logging.basicConfig(
    level=logging.INFO,
    format='{"severity":"%(levelname)s","message":"%(message)s"}',
)

_secret_client = None


def _get_secret_client():
    global _secret_client
    if _secret_client is None:
        _secret_client = secretmanager.SecretManagerServiceClient()
    return _secret_client


def get_secret(secret_name):
    """Retrieve secret from Secret Manager."""
    client = _get_secret_client()
    project_id = os.environ.get("PROJECT_ID")
    name = f"projects/{project_id}/secrets/{secret_name}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")


class ElasticsearchClient:
    def __init__(self):
        self.client = None
        self._initialized = False

    def _ensure_connected(self):
        """Lazy initialization — connect on first request, not at import time."""
        if self._initialized:
            return
        self._initialized = True
        try:
            cloud_id = get_secret("elastic-cloud-id")
            password = get_secret("elastic-password")
            self.client = Elasticsearch(
                cloud_id=cloud_id,
                basic_auth=("elastic", password),
                request_timeout=30,
                max_retries=3,
                retry_on_timeout=True,
            )
            info = self.client.info()
            app.logger.info("Connected to Elasticsearch %s", info["version"]["number"])
        except Exception as e:
            app.logger.error("Elasticsearch connection failed: %s", e)
            self.client = None

    def search(self, index, query):
        self._ensure_connected()
        if not self.client:
            return {"error": "Elasticsearch not connected"}
        try:
            return self.client.search(index=index, **query)
        except Exception as e:
            app.logger.error("Search error: %s", e)
            return {"error": str(e)}

    def index_document(self, index, document, doc_id=None):
        self._ensure_connected()
        if not self.client:
            return {"error": "Elasticsearch not connected"}
        try:
            return self.client.index(index=index, document=document, id=doc_id)
        except Exception as e:
            app.logger.error("Indexing error: %s", e)
            return {"error": str(e)}

    def bulk_index(self, index, documents):
        self._ensure_connected()
        if not self.client:
            return {"error": "Elasticsearch not connected"}
        try:
            actions = [{"_index": index, "_source": doc} for doc in documents]
            success, failed = helpers.bulk(self.client, actions, stats_only=True)
            return {"success": success, "failed": failed}
        except Exception as e:
            app.logger.error("Bulk indexing error: %s", e)
            return {"error": str(e)}


es_client = ElasticsearchClient()


@app.route("/", methods=["GET"])
def root():
    return jsonify({
        "service": "Elasticsearch API",
        "endpoints": {
            "GET /": "This page",
            "GET /health": "Health check",
            "POST /search": "Search documents (body: index, query)",
            "POST /index": "Index a document (body: index, document, id?)",
            "POST /bulk": "Bulk index documents (body: index, documents)",
        },
    }), 200


@app.route("/health", methods=["GET"])
def health():
    try:
        es_client._ensure_connected()
        if es_client.client and es_client.client.ping():
            return jsonify({"status": "healthy", "elasticsearch": "connected"}), 200
    except Exception:
        pass
    return jsonify({"status": "degraded", "elasticsearch": "disconnected"}), 503


@app.route("/search", methods=["POST"])
def search():
    data = request.json
    if not data or "query" not in data:
        return jsonify({"error": "Missing query"}), 400
    result = es_client.search(
        index=data.get("index", "my-index"),
        query=data["query"],
    )
    if isinstance(result, dict) and "error" in result:
        return jsonify(result), 500
    return jsonify(result), 200


@app.route("/index", methods=["POST"])
def index_document():
    data = request.json
    if not data or "document" not in data:
        return jsonify({"error": "Missing document"}), 400
    result = es_client.index_document(
        index=data.get("index", "my-index"),
        document=data["document"],
        doc_id=data.get("id"),
    )
    if isinstance(result, dict) and "error" in result:
        return jsonify(result), 500
    return jsonify(result), 201


@app.route("/bulk", methods=["POST"])
def bulk_index():
    data = request.json
    if not data or "documents" not in data:
        return jsonify({"error": "Missing documents"}), 400
    result = es_client.bulk_index(
        index=data.get("index", "my-index"),
        documents=data["documents"],
    )
    if isinstance(result, dict) and "error" in result:
        return jsonify(result), 500
    return jsonify(result), 201


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
