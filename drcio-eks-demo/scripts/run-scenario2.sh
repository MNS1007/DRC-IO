#!/bin/bash
set -euo pipefail
SCENARIO_DIR=${1:-"experiment-scenario2-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$SCENARIO_DIR"

NAMESPACE="fraud-detection"
SERVICE_URL=$(kubectl get svc gnn-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Scaling DRC-IO controller to zero"
if kubectl get daemonset drcio-controller -n "$NAMESPACE" >/dev/null 2>&1; then
  if ! kubectl scale daemonset drcio-controller --replicas=0 -n "$NAMESPACE"; then
    echo "  (warning: failed to scale controller to 0)"
  fi
else
  echo "  (controller not found, skipping)"
fi

echo "Ensuring LP batch job is running"
kubectl apply -f kubernetes/workloads/lp-job.yaml
sleep 30

python3 scripts/load-generator.py \
  --url "http://$SERVICE_URL" \
  --rps 6 --max-workers 6 --latency-scale 5 \
  --duration 300 \
  --output "$SCENARIO_DIR/scenario2-no-drcio.csv"

python3 scripts/export-prometheus.py --duration 300 --output "$SCENARIO_DIR/scenario2-metrics.json"
