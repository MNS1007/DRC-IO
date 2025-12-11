#!/bin/bash
set -euo pipefail

SCENARIO_DIR=${1:-"experiment-scenario1-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$SCENARIO_DIR"

NAMESPACE="fraud-detection"
SERVICE_URL=$(kubectl get svc gnn-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

rps=1
workers=2
scale=5

echo "Running Scenario 1 (Baseline) -> $SCENARIO_DIR"
python3 scripts/load-generator.py \
  --url "http://$SERVICE_URL" \
  --rps "$rps" \
  --max-workers "$workers" \
  --latency-scale "$scale" \
  --duration 300 \
  --output "$SCENARIO_DIR/scenario1-baseline.csv"

python3 scripts/export-prometheus.py --duration 300 --output "$SCENARIO_DIR/scenario1-metrics.json"
