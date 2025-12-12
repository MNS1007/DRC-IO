#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-monitoring}"
PROM_SERVICE="${PROM_SERVICE:-prometheus-kube-prometheus-prometheus}"
GRAF_SERVICE="${GRAF_SERVICE:-kube-prometheus-stack-grafana}"
PROM_LOCAL_PORT="${PROM_LOCAL_PORT:-9090}"
PROM_REMOTE_PORT="${PROM_REMOTE_PORT:-9090}"
GRAF_LOCAL_PORT="${GRAF_LOCAL_PORT:-3000}"
GRAF_REMOTE_PORT="${GRAF_REMOTE_PORT:-80}"

log() {
  echo "[$(date +%H:%M:%S)] $*"
}

cleanup() {
  if [[ -n "${PROM_PID:-}" ]] && ps -p "$PROM_PID" >/dev/null 2>&1; then
    log "Stopping Prometheus port-forward (PID $PROM_PID)"
    kill "$PROM_PID" 2>/dev/null || true
  fi
  if [[ -n "${GRAF_PID:-}" ]] && ps -p "$GRAF_PID" >/dev/null 2>&1; then
    log "Stopping Grafana port-forward (PID $GRAF_PID)"
    kill "$GRAF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required for port-forwarding" >&2
  exit 1
fi

LOG_DIR="${SCRIPT_DIR}/.pf-logs"
mkdir -p "$LOG_DIR"

log "Starting Prometheus port-forward on http://127.0.0.1:${PROM_LOCAL_PORT}"
kubectl -n "$NAMESPACE" port-forward "svc/${PROM_SERVICE}" \
  "${PROM_LOCAL_PORT}:${PROM_REMOTE_PORT}" \
  >"${LOG_DIR}/prometheus.log" 2>&1 &
PROM_PID=$!
sleep 2
if ! ps -p "$PROM_PID" >/dev/null 2>&1; then
  echo "Failed to establish Prometheus port-forward. See ${LOG_DIR}/prometheus.log" >&2
  exit 1
fi

log "Starting Grafana port-forward on http://127.0.0.1:${GRAF_LOCAL_PORT}"
kubectl -n "$NAMESPACE" port-forward "svc/${GRAF_SERVICE}" \
  "${GRAF_LOCAL_PORT}:${GRAF_REMOTE_PORT}" \
  >"${LOG_DIR}/grafana.log" 2>&1 &
GRAF_PID=$!
sleep 2
if ! ps -p "$GRAF_PID" >/dev/null 2>&1; then
  echo "Failed to establish Grafana port-forward. See ${LOG_DIR}/grafana.log" >&2
  exit 1
fi

echo ""
log "Prometheus available at http://127.0.0.1:${PROM_LOCAL_PORT}"
log "Grafana available at    http://127.0.0.1:${GRAF_LOCAL_PORT} (admin / admin123)"
log "Forwarding logs -> ${LOG_DIR}"
echo ""
log "Press Ctrl+C to stop port-forwarding"
wait
