#!/bin/bash
##############################################################################
# Deploy All DRC-IO Components to Kubernetes
#
# This script deploys all DRC-IO components in the correct order:
#   1. Namespace and RBAC
#   2. Storage classes
#   3. DRC-IO controller
#   4. Workloads (high-priority and low-priority)
#
# Usage:
#   ./deploy-all.sh [OPTIONS]
#
# Options:
#   --skip-controller   Skip deploying DRC-IO controller
#   --skip-workloads    Skip deploying workloads
#   --dry-run           Show what would be deployed without applying
##############################################################################

set -e
set -u
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
K8S_DIR="$PROJECT_ROOT/kubernetes"

# Options
SKIP_CONTROLLER=false
SKIP_WORKLOADS=false
DRY_RUN=false

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}ℹ ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
}

##############################################################################
# Parse Arguments
##############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-controller)
                SKIP_CONTROLLER=true
                shift
                ;;
            --skip-workloads)
                SKIP_WORKLOADS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --skip-controller    Skip deploying DRC-IO controller"
                echo "  --skip-workloads     Skip deploying workloads"
                echo "  --dry-run            Show what would be deployed"
                echo "  --help, -h           Show this help message"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

##############################################################################
# kubectl wrapper
##############################################################################

k8s_apply() {
    local file=$1
    local description=$2

    log_info "Deploying: $description"

    if [ "$DRY_RUN" = true ]; then
        log_warning "[DRY RUN] Would apply: $file"
        kubectl apply -f "$file" --dry-run=client
    else
        kubectl apply -f "$file"
        log_success "Deployed: $description"
    fi
}

##############################################################################
# Deployment Steps
##############################################################################

check_prerequisites() {
    log_section "Checking Prerequisites"

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    log_success "Connected to cluster: $(kubectl config current-context)"

    # Check if images are updated
    if grep -r "<AWS_ACCOUNT_ID>" "$K8S_DIR" &> /dev/null; then
        log_warning "Found placeholder <AWS_ACCOUNT_ID> in manifests"
        log_warning "Run ./build-push.sh to update image references"

        read -p "Continue anyway? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            exit 1
        fi
    fi
}

deploy_namespace() {
    log_section "Deploying Namespace"

    if [ -f "$K8S_DIR/workloads/namespace.yaml" ]; then
        k8s_apply "$K8S_DIR/workloads/namespace.yaml" "Namespace"
    else
        log_info "Using default namespace"
    fi
}

deploy_storage() {
    log_section "Deploying Storage Configuration"

    k8s_apply "$K8S_DIR/workloads/storage.yaml" "Storage classes and volumes"
}

deploy_drcio_controller() {
    if [ "$SKIP_CONTROLLER" = true ]; then
        log_section "Skipping DRC-IO Controller"
        return
    fi

    log_section "Deploying DRC-IO Controller"

    # Service account
    k8s_apply "$K8S_DIR/drcio/serviceaccount.yaml" "Service account"

    # RBAC
    k8s_apply "$K8S_DIR/drcio/rbac.yaml" "RBAC roles and bindings"

    # DaemonSet
    k8s_apply "$K8S_DIR/drcio/daemonset.yaml" "DRC-IO controller DaemonSet"

    # Wait for controller to be ready
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for DRC-IO controller to be ready..."
        kubectl rollout status daemonset/drcio-controller --timeout=120s || \
            log_warning "Controller may not be ready yet"
    fi
}

deploy_workloads() {
    if [ "$SKIP_WORKLOADS" = true ]; then
        log_section "Skipping Workloads"
        return
    fi

    log_section "Deploying Workloads"

    # High-priority service
    log_info "Deploying high-priority GNN service..."
    k8s_apply "$K8S_DIR/workloads/hp-deployment.yaml" "High-priority deployment"
    k8s_apply "$K8S_DIR/workloads/hp-service.yaml" "High-priority service"

    # Low-priority batch job
    log_info "Deploying low-priority batch job..."
    k8s_apply "$K8S_DIR/workloads/lp-job.yaml" "Low-priority batch job"

    # Wait for deployments
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for deployments to be ready..."
        kubectl rollout status deployment/hp-gnn-service --timeout=180s || \
            log_warning "High-priority deployment may not be ready yet"
    fi
}

verify_deployment() {
    if [ "$DRY_RUN" = true ]; then
        log_section "Skipping Verification (Dry Run)"
        return
    fi

    log_section "Verifying Deployment"

    echo ""
    log_info "All pods:"
    kubectl get pods -A -l 'app in (drcio-controller,hp-gnn-service,lp-batch)'

    echo ""
    log_info "Services:"
    kubectl get svc -l 'app in (hp-gnn-service,drcio-controller)'

    echo ""
    log_info "Jobs:"
    kubectl get jobs -l 'app=lp-batch'

    echo ""
    log_info "DaemonSets:"
    kubectl get daemonset drcio-controller
}

get_service_endpoints() {
    if [ "$DRY_RUN" = true ]; then
        return
    fi

    log_section "Service Endpoints"

    # Get LoadBalancer IP/hostname for HP service
    local lb_host=$(kubectl get svc hp-gnn-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
    local lb_ip=$(kubectl get svc hp-gnn-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

    echo ""
    echo "High-Priority GNN Service:"
    if [ -n "$lb_ip" ]; then
        echo "  External URL: http://$lb_ip"
    elif [ "$lb_host" != "pending" ]; then
        echo "  External URL: http://$lb_host"
    else
        echo "  External URL: pending (LoadBalancer provisioning...)"
        echo "  Port-forward: kubectl port-forward svc/hp-gnn-service 5000:80"
    fi

    echo ""
    echo "DRC-IO Controller Metrics:"
    echo "  Port-forward: kubectl port-forward -n default ds/drcio-controller 9100:9100"
    echo "  Then access: http://localhost:9100/metrics"
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    log_section "✅ Deployment Complete"

    echo ""
    echo "🎯 Deployed Components:"

    if [ "$SKIP_CONTROLLER" = false ]; then
        echo "  ✓ DRC-IO Controller (DaemonSet)"
    fi

    if [ "$SKIP_WORKLOADS" = false ]; then
        echo "  ✓ High-Priority GNN Service"
        echo "  ✓ Low-Priority Batch Job"
    fi

    echo "  ✓ Storage Configuration"

    echo ""
    echo "📊 Monitor Your Deployment:"
    echo "  Grafana:    http://localhost:3000"
    echo "  Prometheus: http://localhost:9090"
    echo ""
    echo "🔍 Useful Commands:"
    echo "  kubectl get pods -A"
    echo "  kubectl logs -f -l app=drcio-controller"
    echo "  kubectl logs -f -l app=hp-gnn-service"
    echo "  kubectl describe job lp-batch-stress"
    echo ""
    echo "🧪 Run Experiments:"
    echo "  cd scripts && ./run-experiment.sh"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    parse_args "$@"

    log_section "🚀 Deploying DRC-IO to Kubernetes"

    if [ "$DRY_RUN" = true ]; then
        log_warning "Running in DRY RUN mode"
    fi

    check_prerequisites
    deploy_namespace
    deploy_storage
    deploy_drcio_controller
    deploy_workloads
    verify_deployment
    get_service_endpoints
    print_summary
}

# Run main function
main "$@"
