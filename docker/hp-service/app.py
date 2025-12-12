import os
import time
import json
import logging
from datetime import datetime
from flask import Flask, request, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, REGISTRY
import tempfile
import random

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration from environment
SLA_THRESHOLD_MS = int(os.getenv('SLA_THRESHOLD_MS', '500'))
DATA_DIR = os.getenv('DATA_DIR', '/data')
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
MODEL_IO_MB = int(os.getenv('MODEL_IO_MB', '10'))
GRAPH_IO_MB = int(os.getenv('GRAPH_IO_MB', '20'))

# Prometheus metrics
REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)

REQUEST_DURATION = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration in seconds',
    ['endpoint'],
    buckets=(0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0)
)

SLA_VIOLATIONS = Counter(
    'sla_violations_total',
    'Total SLA violations (requests > threshold)'
)

DISK_READ_BYTES = Counter(
    'disk_read_bytes_total',
    'Total bytes read from disk'
)

DISK_READ_DURATION = Histogram(
    'disk_read_duration_seconds',
    'Disk read duration in seconds',
    buckets=(0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 1.0, 2.0)
)

ACTIVE_REQUESTS = Gauge(
    'active_requests',
    'Number of active requests'
)


def simulate_disk_io(size_mb):
    """
    Simulate disk I/O by reading/writing actual files.
    This creates real I/O load that competes with LP batch job.
    """
    start = time.time()
    chunk_size = 1024 * 1024  # 1MB chunks
    temp_file = os.path.join(tempfile.gettempdir(), f'io_test_{os.getpid()}_{int(time.time()*1000)}.dat')

    try:
        with open(temp_file, 'wb') as f:
            for _ in range(size_mb):
                f.write(os.urandom(chunk_size))

        os.sync()  # ensure data written to disk

        with open(temp_file, 'rb') as f:
            while f.read(chunk_size):
                pass

        DISK_READ_BYTES.inc(size_mb * chunk_size)
    finally:
        if os.path.exists(temp_file):
            os.remove(temp_file)

    duration = time.time() - start
    DISK_READ_DURATION.observe(duration)
    return duration


def simulate_gnn_inference():
    """
    Simulate GNN computation time.
    In production, this would be actual PyTorch Geometric forward pass.
    """
    compute_time = random.uniform(0.05, 0.2)
    time.sleep(compute_time)
    return compute_time


@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint for Kubernetes probes."""
    return jsonify({'status': 'healthy', 'timestamp': datetime.utcnow().isoformat()})


@app.route('/predict', methods=['POST'])
def predict():
    """
    Main prediction endpoint.
    Simulates GNN-based fraud detection with realistic I/O patterns.
    """
    ACTIVE_REQUESTS.inc()
    start_time = time.time()

    try:
        data = request.get_json() or {}
        transaction_id = data.get('transaction_id', f'txn_{int(time.time()*1000)}')

        logger.info("Processing transaction: %s", transaction_id)

        model_load_time = simulate_disk_io(MODEL_IO_MB)
        graph_load_time = simulate_disk_io(GRAPH_IO_MB)
        compute_time = simulate_gnn_inference()

        fraud_score = random.uniform(0, 1)
        is_fraud = fraud_score > 0.7

        total_latency = time.time() - start_time
        latency_ms = total_latency * 1000

        if latency_ms > SLA_THRESHOLD_MS:
            SLA_VIOLATIONS.inc()
            logger.warning("SLA violation: %.1fms > %dms", latency_ms, SLA_THRESHOLD_MS)

        REQUEST_DURATION.labels(endpoint='/predict').observe(total_latency)
        REQUEST_COUNT.labels(method='POST', endpoint='/predict', status='200').inc()

        logger.info(
            "Transaction %s: Total=%.1fms (Model=%.1fms, Graph=%.1fms, Compute=%.1fms) Score=%.3f",
            transaction_id,
            latency_ms,
            model_load_time * 1000,
            graph_load_time * 1000,
            compute_time * 1000,
            fraud_score,
        )

        response = {
            'transaction_id': transaction_id,
            'fraud_score': round(fraud_score, 3),
            'prediction': 'fraud' if is_fraud else 'legitimate',
            'latency_ms': round(latency_ms, 2),
            'breakdown': {
                'model_load_ms': round(model_load_time * 1000, 2),
                'graph_load_ms': round(graph_load_time * 1000, 2),
                'compute_ms': round(compute_time * 1000, 2),
            },
            'sla_met': latency_ms <= SLA_THRESHOLD_MS,
            'timestamp': datetime.utcnow().isoformat(),
        }

        return jsonify(response), 200
    except Exception as exc:
        logger.error("Error processing request: %s", exc, exc_info=True)
        REQUEST_COUNT.labels(method='POST', endpoint='/predict', status='500').inc()
        return jsonify({'error': str(exc)}), 500
    finally:
        ACTIVE_REQUESTS.dec()


@app.route('/metrics', methods=['GET'])
def metrics():
    """Prometheus metrics endpoint."""
    return generate_latest(REGISTRY), 200, {'Content-Type': 'text/plain; charset=utf-8'}


@app.route('/', methods=['GET'])
def index():
    """Root endpoint with service info."""
    return jsonify({
        'service': 'GNN Fraud Detection',
        'version': '1.0',
        'endpoints': {
            'predict': 'POST /predict',
            'health': 'GET /health',
            'metrics': 'GET /metrics',
        },
        'sla_threshold_ms': SLA_THRESHOLD_MS,
    })


if __name__ == '__main__':
    os.makedirs(DATA_DIR, exist_ok=True)
    logger.info("Starting GNN Fraud Detection Service")
    logger.info("SLA Threshold: %dms", SLA_THRESHOLD_MS)
    logger.info("Data Directory: %s", DATA_DIR)
    app.run(host='0.0.0.0', port=8000, debug=False)
