#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SCENARIO_DIR=${1:-"experiment-scenario2-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$SCENARIO_DIR"

NAMESPACE="fraud-detection"
DURATION_SECONDS=300
CONTENT_RPS=10
CONTENT_WORKERS=10
CONTENT_LAT_SCALE=1
LP_JOB_MANIFEST="$REPO_ROOT/kubernetes/workloads/lp-job.yaml"
if [[ ! -f "$LP_JOB_MANIFEST" ]]; then
  echo "Error: LP job manifest not found at $LP_JOB_MANIFEST"
  exit 1
fi

echo "Retrieving HP service URL..."
SERVICE_URL=$(kubectl get svc gnn-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$SERVICE_URL" ]]; then
  echo "Error: Unable to determine LoadBalancer hostname for gnn-service in namespace $NAMESPACE"
  exit 1
fi
echo "Service URL: http://$SERVICE_URL"
echo ""

echo "Scaling DRC-IO controller to zero..."
if kubectl get daemonset drcio-controller -n "$NAMESPACE" >/dev/null 2>&1; then
  if ! kubectl scale daemonset drcio-controller --replicas=0 -n "$NAMESPACE"; then
    echo "  (warning: failed to scale controller to 0)"
  fi
else
  echo "  (controller not found, skipping)"
fi

echo "Ensuring LP batch job is running..."
kubectl apply -f "$LP_JOB_MANIFEST"
echo "Waiting 30 seconds for LP job to saturate disks..."
sleep 30

python3 "$SCRIPT_DIR/load-generator.py" \
  --url "http://$SERVICE_URL" \
  --rps "$CONTENT_RPS" \
  --max-workers "$CONTENT_WORKERS" \
  --latency-scale "$CONTENT_LAT_SCALE" \
  --duration "$DURATION_SECONDS" \
  --output "$SCENARIO_DIR/scenario2-no-drcio.csv"

if [[ -f "$SCRIPT_DIR/export-prometheus.py" ]]; then
  python3 "$SCRIPT_DIR/export-prometheus.py" --duration "$DURATION_SECONDS" --output "$SCENARIO_DIR/scenario2-metrics.json"
else
  echo "Warning: export-prometheus.py not found; skipping metrics export"
fi

echo "Cleaning up LP batch job..."
kubectl delete job batch-stress -n "$NAMESPACE" >/dev/null 2>&1 || true
