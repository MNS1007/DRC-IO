#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
DASHBOARD_FILE="dashboards/drcio-dashboard.json"

log_step() { echo -e "${YELLOW}[$1]${NC} $2"; }
log_ok() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}!${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

PORT_FORWARD_PID=""
API_KEY=""
API_KEY_ID=""

start_port_forward() {
    if [[ "$GRAFANA_URL" =~ ^https?://(localhost|127\.0\.0\.1)(:([0-9]+))? ]]; then
        local port="${BASH_REMATCH[3]:-3000}"
        log_step "0/5" "Starting Grafana port-forward on localhost:$port"
        kubectl port-forward -n monitoring svc/prometheus-grafana "${port}:80" >/dev/null 2>&1 &
        PORT_FORWARD_PID=$!
        sleep 5
    fi
}

stop_port_forward() {
    if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
        kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
        PORT_FORWARD_PID=""
    fi
}

cleanup_key() {
    if [[ -n "${API_KEY_ID:-}" && -n "${API_KEY:-}" ]]; then
        curl -s -X DELETE "${GRAFANA_URL}/api/auth/keys/${API_KEY_ID}" \
            -H "Authorization: Bearer ${API_KEY}" >/dev/null 2>&1 || true
    fi
}

cleanup_all() {
    cleanup_key
    stop_port_forward
}

trap cleanup_all EXIT

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Importing Grafana Dashboard                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSWORD_FILE="infrastructure/grafana-password.txt"
if [[ ! -f "$PASSWORD_FILE" ]]; then
    log_step "*" "Retrieving Grafana password from cluster secret"
    GRAFANA_PASS=$(kubectl get secret -n monitoring prometheus-grafana \
        -o jsonpath='{.data.admin-password}' | base64 --decode)
    printf "%s" "$GRAFANA_PASS" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
else
    GRAFANA_PASS=$(<"$PASSWORD_FILE")
fi

start_port_forward

log_step "1/5" "Waiting for Grafana to be ready..."
for _ in {1..30}; do
    if curl -s "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
        log_ok "Grafana API reachable"
        break
    fi
    printf "."
    sleep 2
done || true
if ! curl -s "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
    log_error "Grafana did not become ready"
    echo "Ensure port-forwarding is active:"
    echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    exit 1
fi
echo ""

AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASS}")

log_step "2/4" "Ensuring Prometheus datasource exists..."
DATASOURCE_EXISTS=$(curl -s "${AUTH[@]}" \
    "${GRAFANA_URL}/api/datasources/name/Prometheus" | jq -r '.id // empty')
if [[ -z "$DATASOURCE_EXISTS" ]]; then
    log_warn "Prometheus datasource missing; creating it"
    curl -s -X POST "${GRAFANA_URL}/api/datasources" \
        "${AUTH[@]}" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "Prometheus",
            "type": "prometheus",
            "url": "http://prometheus-kube-prometheus-prometheus.monitoring:9090",
            "access": "proxy",
            "isDefault": true,
            "jsonData": { "timeInterval": "5s" }
        }' >/dev/null
    log_ok "Prometheus datasource created"
else
    log_ok "Prometheus datasource already exists (id: $DATASOURCE_EXISTS)"
fi
echo ""

log_step "3/4" "Importing DRC-IO dashboard"
if [[ ! -f "$DASHBOARD_FILE" ]]; then
    log_error "Dashboard file not found: $DASHBOARD_FILE"
    exit 1
fi
DASHBOARD_JSON=$(cat "$DASHBOARD_FILE")
IMPORT_PAYLOAD=$(jq -n --argjson dashboard "$DASHBOARD_JSON" \
    '{dashboard:$dashboard, overwrite:true, inputs:[], folderId:0}')
IMPORT_RESPONSE=$(curl -s -X POST "${GRAFANA_URL}/api/dashboards/db" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$IMPORT_PAYLOAD")
DASHBOARD_UID=$(echo "$IMPORT_RESPONSE" | jq -r '.uid // empty')
if [[ -z "$DASHBOARD_UID" ]]; then
    log_error "Dashboard import failed"
    echo "Response: $IMPORT_RESPONSE"
    exit 1
fi
log_ok "Dashboard imported (UID: $DASHBOARD_UID)"
echo ""

log_step "4/4" "Setting imported dashboard as home"
curl -s -X PUT "${GRAFANA_URL}/api/org/preferences" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"homeDashboardUID\": \"${DASHBOARD_UID}\"}" >/dev/null
log_ok "Home dashboard updated"
echo ""

echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✅ Dashboard Import Complete!               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Access Dashboard:${NC}"
echo "  URL: ${GRAFANA_URL}"
echo "  Username: ${GRAFANA_USER}"
echo "  Password: ${GRAFANA_PASS}"
echo ""
echo -e "${BLUE}Direct Link:${NC}"
echo "  ${GRAFANA_URL}/d/${DASHBOARD_UID}/drc-io-gnn-fraud-detection-monitoring"
echo ""
echo "Dashboard refreshes every 5 seconds."
echo ""
