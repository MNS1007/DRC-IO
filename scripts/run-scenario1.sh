#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR=${1:-"experiment-scenario1-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$SCENARIO_DIR"

NAMESPACE="fraud-detection"
DURATION_SECONDS=300
BASELINE_RPS=1
BASELINE_WORKERS=2
BASELINE_LAT_SCALE=5

echo "Retrieving HP service URL..."
SERVICE_URL=$(kubectl get svc gnn-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$SERVICE_URL" ]]; then
  echo "Error: Unable to determine LoadBalancer hostname for gnn-service in namespace $NAMESPACE"
  exit 1
fi
echo "Service URL: http://$SERVICE_URL"
echo ""

echo "Ensuring LP batch job is not running..."
kubectl delete job batch-stress -n "$NAMESPACE" >/dev/null 2>&1 || true

echo "Running Scenario 1 (Baseline) -> $SCENARIO_DIR"
python3 "$SCRIPT_DIR/load-generator.py" \
  --url "http://$SERVICE_URL" \
  --rps "$BASELINE_RPS" \
  --max-workers "$BASELINE_WORKERS" \
  --latency-scale "$BASELINE_LAT_SCALE" \
  --duration "$DURATION_SECONDS" \
  --output "$SCENARIO_DIR/scenario1-baseline.csv"

if [[ -f "$SCRIPT_DIR/export-prometheus.py" ]]; then
  python3 "$SCRIPT_DIR/export-prometheus.py" --duration "$DURATION_SECONDS" --output "$SCENARIO_DIR/scenario1-metrics.json"
else
  echo "Warning: export-prometheus.py not found; skipping metrics export"
fi
