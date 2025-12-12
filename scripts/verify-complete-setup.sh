#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          DRC-IO Complete Setup Verification                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

check() {
    local name=$1
    local command=$2
    printf "Checking %s... " "$name"
    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

echo "Infrastructure Checks:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
check "EKS cluster accessible" "kubectl cluster-info"
check "Monitoring namespace" "kubectl get namespace monitoring"
check "Fraud-detection namespace" "kubectl get namespace fraud-detection"
check "Prometheus running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running"
check "Grafana running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running"
echo ""

echo "Workload Checks:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
check "HP service deployed" "kubectl get deployment gnn-service -n fraud-detection"
check "HP service pods running" "kubectl get pods -n fraud-detection -l app=gnn-service --field-selector=status.phase=Running"
check "HP service endpoint" "kubectl get svc gnn-service -n fraud-detection -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' && echo"
check "DRC-IO controller deployed" "kubectl get daemonset drcio-controller -n fraud-detection"
check "DRC-IO pod running" "kubectl get pods -n fraud-detection -l app=drcio-controller --field-selector=status.phase=Running"
echo ""

echo "Service Checks:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
check "Grafana accessible" "curl -s http://localhost:3000/api/health"
check "Prometheus accessible" "curl -s http://localhost:9090/-/healthy"
SERVICE_URL=$(kubectl get svc gnn-service -n fraud-detection -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "$SERVICE_URL" ]]; then
    check "HP service responding" "curl -s -X POST http://${SERVICE_URL}/predict -H 'Content-Type: application/json' -d '{\"transaction_id\":\"test\"}' --max-time 5"
else
    echo -e "${YELLOW}! Skipping HP service response check (no LoadBalancer hostname yet)${NC}"
fi
echo ""

echo "Metrics Checks:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
check "HP service metrics" "curl -s 'http://localhost:9090/api/v1/query?query=http_requests_total' | grep -q '\"status\":\"success\"'"
check "DRC-IO metrics" "curl -s 'http://localhost:9090/api/v1/query?query=drcio_hp_weight' | grep -q '\"status\":\"success\"'"
echo ""

echo "Script Files:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
check "load-generator.py exists" "test -f scripts/load-generator.py"
check "run-experiments.sh exists" "test -f scripts/run-experiments.sh"
check "export-prometheus.py exists" "test -f scripts/export-prometheus.py"
check "analyze-results.py exists" "test -f scripts/analyze-results.py"
check "plot-results.py exists" "test -f scripts/plot-results.py"
check "import-dashboard.sh exists" "test -f scripts/import-dashboard.sh"
check "Dashboard JSON exists" "test -f dashboards/drcio-dashboard.json"
echo ""

echo "Python Dependencies:"
echo "━━━━━━━━━━━━━━━━━━━━━━"
check "pandas installed" "python3 -c 'import pandas'"
check "numpy installed" "python3 -c 'import numpy'"
check "matplotlib installed" "python3 -c 'import matplotlib'"
check "seaborn installed" "python3 -c 'import seaborn'"
check "requests installed" "python3 -c 'import requests'"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo -e "  Total Checks: $((PASSED + FAILED))"
echo -e "  ${GREEN}Passed: $PASSED${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✅ ALL CHECKS PASSED!${NC}"
    echo ""
    echo "You are ready to run experiments!"
    echo ""
    echo "Next steps:"
    echo "  1. Import Grafana dashboard: ./scripts/import-dashboard.sh"
    echo "  2. Run experiments: ./scripts/run-experiments.sh"
    echo "  3. View results in Grafana: http://localhost:3000"
    echo ""
else
    echo -e "${RED}⚠️  SOME CHECKS FAILED${NC}"
    echo ""
    echo "Please fix the failed checks before proceeding."
    echo ""
fi
