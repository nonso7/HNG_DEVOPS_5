import os
import socket
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)

ENV_ID = os.environ.get("ENV_ID", "unknown")
STARTED_AT = datetime.now(timezone.utc).isoformat()

# Exposes /metrics. Every request/latency series is labeled with env_id
# so Grafana can group / filter by environment.
metrics = PrometheusMetrics(app, static_labels={"env_id": ENV_ID})
metrics.info("sandbox_app_info", "Demo app info", env_id=ENV_ID, started_at=STARTED_AT)


@app.route("/")
def index():
    return jsonify(
        message="Hello from the sandbox demo app",
        env_id=ENV_ID,
        hostname=socket.gethostname(),
        started_at=STARTED_AT,
    )


@app.route("/health")
def health():
    return jsonify(status="ok", env_id=ENV_ID), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
