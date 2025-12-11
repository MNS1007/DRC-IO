#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SCENARIO_DIR=${1:-"experiment-scenario3-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$SCENARIO_DIR"
NAMESPACE="fraud-detection"
SERVICE_URL=""
if kubectl get svc gnn-service -n "$NAMESPACE" >/dev/null 2>&1; then
  SERVICE_URL=$(kubectl get svc gnn-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
else
  echo "Error: gnn-service not found in namespace $NAMESPACE"
  exit 1
fi

if ! kubectl get daemonset drcio-controller -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "DRC-IO controller not found; deploying manifests"
  kubectl apply -f "$REPO_ROOT/kubernetes/drcio/serviceaccount.yaml"
  kubectl apply -f "$REPO_ROOT/kubernetes/drcio/rbac.yaml"
  kubectl apply -f "$REPO_ROOT/kubernetes/drcio/daemonset.yaml"
  kubectl apply -f "$REPO_ROOT/kubernetes/drcio/service.yaml"
  sleep 10
fi
if ! kubectl scale daemonset drcio-controller --replicas=1 -n "$NAMESPACE"; then
  echo "Warning: failed to scale drcio-controller to 1 (continuing)"
fi
sleep 30

python3 "$SCRIPT_DIR/load-generator.py" \
  --url "http://$SERVICE_URL" \
  --rps 6 --max-workers 6 --latency-scale 15 \
  --duration 300 \
  --output "$SCENARIO_DIR/scenario3-with-drcio.csv"

python3 "$SCRIPT_DIR/export-prometheus.py" --duration 300 --output "$SCENARIO_DIR/scenario3-metrics.json"
