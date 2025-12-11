#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

log_section() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ $1${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
}

log_step() {
    echo -e "${YELLOW}[$1]${NC} $2"
}

log_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}!${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

ensure_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required tool '$1' not found"
        exit 1
    fi
}

log_section "Deploying DRC-IO to Kubernetes"

ensure_tool kubectl
ensure_tool curl

if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "Cannot connect to Kubernetes cluster"
    echo "Run: aws eks update-kubeconfig --name drcio-demo --region us-east-1"
    exit 1
fi
log_ok "Connected to Kubernetes cluster"
echo ""

log_step "1/5" "Creating namespace and storage"
kubectl apply -f "$REPO_ROOT/kubernetes/workloads/namespace.yaml"
kubectl apply -f "$REPO_ROOT/kubernetes/workloads/storage.yaml"

log_step "1a" "Waiting for PVC shared-data to bind"
if ! kubectl wait --for=condition=Bound pvc/shared-data -n fraud-detection --timeout=120s; then
    log_warn "PVC not bound within timeout; continuing (may bind later)"
fi
log_ok "Namespace and storage applied"
echo ""

log_step "2/5" "Deploying High-Priority GNN service"
kubectl apply -f "$REPO_ROOT/kubernetes/workloads/hp-deployment.yaml"
kubectl apply -f "$REPO_ROOT/kubernetes/workloads/hp-service.yaml"

log_step "2a" "Waiting for HP pods to become ready"
if ! kubectl wait --for=condition=Ready pod -l app=gnn-service -n fraud-detection --timeout=300s; then
    log_warn "HP pods not ready yet; check with 'kubectl get pods -n fraud-detection'"
fi
log_ok "HP service manifests applied"
echo ""

log_step "3/5" "Retrieving LoadBalancer hostname for gnn-service"
SERVICE_URL_FILE="$REPO_ROOT/service-url.txt"
rm -f "$SERVICE_URL_FILE"
LB_HOSTNAME=""
for i in {1..60}; do
    LB_HOSTNAME=$(kubectl get svc gnn-service -n fraud-detection -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n "$LB_HOSTNAME" ]]; then
        echo "$LB_HOSTNAME" > "$SERVICE_URL_FILE"
        log_ok "HP Service URL: http://$LB_HOSTNAME"
        break
    fi
    printf "."
    sleep 5
done
echo ""
if [[ -z "$LB_HOSTNAME" ]]; then
    log_warn "LoadBalancer still provisioning; check later with 'kubectl get svc gnn-service -n fraud-detection'"
fi
echo ""

log_step "4/5" "Deploying DRC-IO controller"
kubectl apply -f "$REPO_ROOT/kubernetes/drcio/serviceaccount.yaml"
kubectl apply -f "$REPO_ROOT/kubernetes/drcio/rbac.yaml"
kubectl apply -f "$REPO_ROOT/kubernetes/drcio/daemonset.yaml"
kubectl apply -f "$REPO_ROOT/kubernetes/drcio/service.yaml"

log_step "4a" "Waiting for DRC-IO pods"
sleep 10
if ! kubectl wait --for=condition=Ready pod -l app=drcio-controller -n fraud-detection --timeout=180s; then
    log_warn "Controller pods not ready yet; inspect with 'kubectl get pods -n fraud-detection'"
fi
log_ok "DRC-IO controller manifests applied"
echo ""

log_step "5/5" "Verifying deployment"

echo "Pods:"
kubectl get pods -n fraud-detection -o wide
echo ""
echo "Services:"
kubectl get svc -n fraud-detection
echo ""

if [[ -f "$SERVICE_URL_FILE" ]]; then
    SERVICE_URL=$(cat "$SERVICE_URL_FILE")
    echo "Testing HP service endpoint..."
    if curl -s -X POST "http://$SERVICE_URL/predict" \
        -H "Content-Type: application/json" \
        -d '{"transaction_id":"test_123","amount":100}' \
        --max-time 10 >/dev/null 2>&1; then
        log_ok "HP service responded successfully"
    else
        log_warn "HP service not responding yet; retry later"
    fi
    echo ""
fi

cat > "$REPO_ROOT/deployment-info.txt" <<EOF
DRC-IO Deployment Information
==============================

Deployment Date: $(date)
Namespace: fraud-detection

Resources:
----------
HP Service (GNN):    2 pods (Deployment gnn-service)
DRC-IO Controller:   1 pod per node (DaemonSet drcio-controller)
LP Batch Job:        Not yet started (apply lp-job when ready)

HP Service URL:
---------------
$(cat "$SERVICE_URL_FILE" 2>/dev/null || echo "Pending...")

Helpful Commands:
-----------------
kubectl get pods -n fraud-detection
kubectl logs -f deployment/gnn-service -n fraud-detection
kubectl logs -f daemonset/drcio-controller -n fraud-detection
kubectl get svc gnn-service -n fraud-detection
kubectl apply -f kubernetes/workloads/lp-job.yaml   # start LP job
kubectl delete job batch-stress -n fraud-detection  # stop LP job

Test HP service:
curl -X POST http://$(cat "$SERVICE_URL_FILE" 2>/dev/null || echo "<service-host>")/predict \\
  -H "Content-Type: application/json" \\
  -d '{"transaction_id":"test","amount":100}'

EOF

log_ok "Deployment info saved to deployment-info.txt"
echo ""

log_section "✅ Deployment Complete!"
echo -e "${BLUE}HP Service URL:${NC}"
if [[ -f "$SERVICE_URL_FILE" ]]; then
    echo "  http://$(cat "$SERVICE_URL_FILE")"
else
    echo "  Pending... check later with: kubectl get svc gnn-service -n fraud-detection"
fi
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. Import Grafana dashboard (if needed)."
echo "  2. Start LP batch job when ready: kubectl apply -f kubernetes/workloads/lp-job.yaml"
echo "  3. Tail controller logs: kubectl logs -f daemonset/drcio-controller -n fraud-detection"
echo ""
