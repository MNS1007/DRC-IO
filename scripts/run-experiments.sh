#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

NAMESPACE="fraud-detection"
DURATION_SECONDS=300
BASELINE_RPS=10
BASELINE_WORKERS=10
BASELINE_LAT_SCALE=5
CONTENT_RPS=10
CONTENT_WORKERS=10
CONTENT_LAT_SCALE=5
RESULTS_DIR="experiment-results-$(date +%Y%m%d-%H%M%S)"

log_header() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              DRC-IO EXPERIMENTAL EVALUATION                    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Scenarios:"
    echo "  1. Baseline (HP only)"
    echo "  2. Contention without DRC-IO"
    echo "  3. Solution with DRC-IO"
    echo ""
    echo "Configuration:"
    echo "  Duration: ${DURATION_SECONDS}s per scenario"
    echo "  Baseline load: ${BASELINE_RPS} req/s (max ${BASELINE_WORKERS} workers)"
    echo "  Contention load: ${CONTENT_RPS} req/s (max ${CONTENT_WORKERS} workers)"
    echo "  Results directory: ${RESULTS_DIR}"
    echo ""
}

log_block() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ $1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

ensure_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}✗ Required tool '$1' not found${NC}"
        exit 1
    fi
}

wait_for_stabilization() {
    local seconds="$1"
    echo "Waiting ${seconds}s for system stabilization..."
    for ((i=seconds; i>0; i--)); do
        printf "  %2ds remaining...\r" "$i"
        sleep 1
    done
    echo -e "  ${GREEN}✓ Stabilized${NC}                "
    echo ""
}

run_load_test() {
    local label="$1"
    local output="$2"
    local rps="$3"
    local workers="$4"
    local scale="$5"
    echo "Starting load test for ${label} (${DURATION_SECONDS}s, ${rps} rps, ${workers} workers, scale ${scale})..."
    python3 scripts/load-generator.py \
        --url "http://$SERVICE_URL" \
        --rps "$rps" \
        --max-workers "$workers" \
        --latency-scale "$scale" \
        --duration "$DURATION_SECONDS" \
        --output "$output"
    echo ""
    echo -e "${GREEN}✓ ${label} load test complete${NC}"
    echo ""
}

export_metrics() {
    local label="$1"
    local output="$2"
    if [[ -x scripts/export-prometheus.py ]]; then
        python3 scripts/export-prometheus.py --duration "$DURATION_SECONDS" --output "$output"
    elif [[ -f scripts/export-prometheus.py ]]; then
        python3 scripts/export-prometheus.py --duration "$DURATION_SECONDS" --output "$output"
    else
        echo -e "${YELLOW}! export-prometheus.py not found; skipping metrics export for ${label}${NC}"
    fi
    echo ""
}

analyze_results() {
    if [[ -f scripts/analyze-results.py ]]; then
        python3 scripts/analyze-results.py --input "$RESULTS_DIR"
    else
        echo -e "${YELLOW}! analyze-results.py not found; skipping comparison report${NC}"
    fi
}

log_header
ensure_tool kubectl
ensure_tool python3
ensure_tool curl

read -r -p "Press Enter to start experiments..."
echo ""

mkdir -p "$RESULTS_DIR"

echo "Retrieving HP service URL..."
SERVICE_URL=$(kubectl get svc gnn-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$SERVICE_URL" ]]; then
    echo -e "${RED}✗ Unable to determine LoadBalancer hostname for gnn-service${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Service URL: http://$SERVICE_URL${NC}"
echo ""

echo "Testing service connectivity..."
if ! curl -s -X POST "http://$SERVICE_URL/predict" \
    -H "Content-Type: application/json" \
    -d '{"transaction_id":"connectivity-test"}' \
    --max-time 5 >/dev/null 2>&1; then
    echo -e "${RED}✗ Service not responding${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Service responding${NC}"
echo ""

# Scenario 1
log_block "SCENARIO 1: BASELINE (HP ONLY)"
echo "Ensuring LP batch job is not running..."
kubectl delete job batch-stress -n "$NAMESPACE" >/dev/null 2>&1 || true

echo "Verifying DRC-IO controller is running..."
if ! kubectl get daemonset drcio-controller -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${RED}✗ DRC-IO controller not deployed${NC}"
    exit 1
fi
wait_for_stabilization 30

run_load_test "Scenario 1 (Baseline)" "$RESULTS_DIR/scenario1-baseline.csv" "$BASELINE_RPS" "$BASELINE_WORKERS" "$BASELINE_LAT_SCALE"
echo "Exporting Prometheus metrics..."
export_metrics "Scenario 1" "$RESULTS_DIR/scenario1-metrics.json"
wait_for_stabilization 20

# Scenario 2
log_block "SCENARIO 2: CONTENTION WITHOUT DRC-IO"
echo "Disabling DRC-IO controller..."
kubectl scale daemonset drcio-controller --replicas=0 -n "$NAMESPACE"

echo "Starting LP batch job..."
kubectl apply -f kubernetes/workloads/lp-job.yaml
wait_for_stabilization 45

run_load_test "Scenario 2 (No DRC-IO)" "$RESULTS_DIR/scenario2-no-drcio.csv" "$CONTENT_RPS" "$CONTENT_WORKERS" "$CONTENT_LAT_SCALE"
echo "Exporting Prometheus metrics..."
export_metrics "Scenario 2" "$RESULTS_DIR/scenario2-metrics.json"

# Scenario 3
log_block "SCENARIO 3: SOLUTION WITH DRC-IO"
echo "Re-enabling DRC-IO controller..."
kubectl scale daemonset drcio-controller --replicas=1 -n "$NAMESPACE"
wait_for_stabilization 30

run_load_test "Scenario 3 (With DRC-IO)" "$RESULTS_DIR/scenario3-with-drcio.csv" "$CONTENT_RPS" "$CONTENT_WORKERS" "$CONTENT_LAT_SCALE"
echo "Exporting Prometheus metrics..."
export_metrics "Scenario 3" "$RESULTS_DIR/scenario3-metrics.json"

echo "Collecting DRC-IO logs (last 500 lines)..."
kubectl logs daemonset/drcio-controller -n "$NAMESPACE" --tail=500 > "$RESULTS_DIR/drcio-logs.txt" || true
echo ""

echo "Stopping LP batch job..."
kubectl delete job batch-stress -n "$NAMESPACE" >/dev/null 2>&1 || true
echo ""

echo "Generating comparison report..."
analyze_results
echo ""

echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                ✅ ALL EXPERIMENTS COMPLETE!                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Results directory: $RESULTS_DIR"
echo ""
echo "Generated files:"
ls -lh "$RESULTS_DIR"
echo ""
echo "Next steps:"
echo "  1. Inspect comparison: cat $RESULTS_DIR/comparison.txt (if generated)"
echo "  2. Plot time-series: python3 scripts/plot-results.py --input $RESULTS_DIR"
echo "  3. View Grafana dashboards for deeper insights."
echo ""
