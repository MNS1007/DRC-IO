#!/bin/bash
##############################################################################
# DRC-IO Demo Infrastructure Setup Script
#
# This script automates the complete setup of AWS EKS infrastructure
# for the DRC-IO (Dynamic Resource Control for I/O) demonstration.
#
# Prerequisites:
#   - AWS CLI configured with valid credentials
#   - eksctl (https://eksctl.io/)
#   - kubectl (https://kubernetes.io/docs/tasks/tools/)
#   - helm (https://helm.sh/)
#
# Estimated setup time: 15-20 minutes
##############################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable
set -o pipefail  # Exit on pipe failure

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MONITORING_READY=0

# Configuration
CLUSTER_NAME="drcio-demo"
REGION="us-east-1"
NAMESPACE="monitoring"

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
# Pre-flight Checks
##############################################################################

check_prerequisites() {
    log_section "Checking Prerequisites"

    local missing_tools=()

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws-cli")
    else
        log_success "AWS CLI found: $(aws --version | head -n1)"
    fi

    # Check eksctl
    if ! command -v eksctl &> /dev/null; then
        missing_tools+=("eksctl")
    else
        log_success "eksctl found: $(eksctl version)"
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    else
        log_success "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    else
        log_success "helm found: $(helm version --short)"
    fi

    # Check Docker (optional but recommended)
    if ! command -v docker &> /dev/null; then
        log_warning "Docker not found (optional, needed for building images)"
    else
        log_success "Docker found: $(docker --version)"
    fi

    # Report missing tools
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Installation instructions:"
        echo "  AWS CLI:  https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        echo "  eksctl:   https://eksctl.io/installation/"
        echo "  kubectl:  https://kubernetes.io/docs/tasks/tools/"
        echo "  helm:     https://helm.sh/docs/intro/install/"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        echo "Run: aws configure"
        exit 1
    fi

    local aws_account=$(aws sts get-caller-identity --query Account --output text)
    local aws_user=$(aws sts get-caller-identity --query Arn --output text)
    log_success "AWS authenticated as: $aws_user"
    log_info "AWS Account ID: $aws_account"

    # Check SSH key
    if [ ! -f ~/.ssh/id_rsa.pub ]; then
        log_warning "SSH public key not found at ~/.ssh/id_rsa.pub"
        log_warning "Node SSH access will be disabled"
    fi
}

##############################################################################
# EKS Cluster Setup
##############################################################################

create_eks_cluster() {
    log_section "Creating EKS Cluster"

    # Check if cluster already exists
    if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_warning "Cluster $CLUSTER_NAME already exists"
        read -p "Do you want to delete and recreate it? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log_info "Deleting existing cluster..."
            eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
            log_success "Cluster deleted"
        else
            log_info "Using existing cluster"
            return 0
        fi
    fi

    log_info "Creating EKS cluster (this takes 15-20 minutes)..."
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Region: $REGION"

    eksctl create cluster -f "$SCRIPT_DIR/eks-cluster.yaml"

    log_success "EKS cluster created successfully"
}

update_kubeconfig() {
    log_section "Updating Kubeconfig"

    log_info "Updating kubeconfig for cluster: $CLUSTER_NAME"
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

    # Verify connection
    if kubectl cluster-info &> /dev/null; then
        log_success "Successfully connected to cluster"
        kubectl get nodes
    else
        log_error "Failed to connect to cluster"
        exit 1
    fi
}

##############################################################################
# Kubernetes Add-ons
##############################################################################

install_metrics_server() {
    log_section "Installing Metrics Server"

    if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
        log_info "metrics-server already deployed; skipping reinstall"
        return
    fi

    log_info "Deploying metrics-server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    log_info "Waiting for metrics-server to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system

    log_success "Metrics server installed"
}

install_prometheus_stack() {
    log_section "Installing Prometheus Stack"

    # Add Helm repository
    log_info "Adding Prometheus Helm repository..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    # Create monitoring namespace
    log_info "Creating monitoring namespace..."
    kubectl create namespace $NAMESPACE || log_warning "Namespace already exists"

    # Install kube-prometheus-stack
    log_info "Installing kube-prometheus-stack (Prometheus + Grafana)..."

    if helm list -n $NAMESPACE | grep -q prometheus; then
        log_warning "Prometheus stack already installed, upgrading..."
        helm upgrade prometheus prometheus-community/kube-prometheus-stack \
            -n $NAMESPACE \
            -f "$PROJECT_ROOT/kubernetes/monitoring/prometheus-values.yaml" \
            --wait \
            --timeout 10m
    else
        helm install prometheus prometheus-community/kube-prometheus-stack \
            -n $NAMESPACE \
            -f "$PROJECT_ROOT/kubernetes/monitoring/prometheus-values.yaml" \
            --wait \
            --timeout 10m
    fi

    log_success "Prometheus stack installed"
}

setup_grafana_credentials() {
    log_section "Setting up Grafana"

    log_info "Retrieving Grafana admin password..."

    # Wait for secret to be created
    for i in {1..30}; do
        if kubectl get secret -n $NAMESPACE prometheus-grafana &> /dev/null; then
            break
        fi
        sleep 2
    done

    # Get Grafana password
    local grafana_password=$(kubectl get secret -n $NAMESPACE prometheus-grafana \
        -o jsonpath="{.data.admin-password}" | base64 --decode)

    echo "$grafana_password" > "$SCRIPT_DIR/grafana-password.txt"
    chmod 600 "$SCRIPT_DIR/grafana-password.txt"

    log_success "Grafana credentials saved to: $SCRIPT_DIR/grafana-password.txt"
    log_info "Username: admin"
    log_info "Password: $grafana_password"
}

##############################################################################
# Port Forwarding
##############################################################################

setup_port_forwards() {
    log_section "Setting up Port Forwards"

    # Kill existing port forwards
    log_info "Stopping existing port forwards..."
    pkill -f "kubectl port-forward" || true
    sleep 2

    # Grafana port forward
    log_info "Starting Grafana port forward (3000)..."
    kubectl port-forward -n $NAMESPACE svc/prometheus-grafana 3000:80 > /dev/null 2>&1 &

    # Prometheus port forward
    log_info "Starting Prometheus port forward (9090)..."
    kubectl port-forward -n $NAMESPACE svc/prometheus-kube-prometheus-prometheus 9090:9090 > /dev/null 2>&1 &

    # Wait for port forwards to be ready
    sleep 5

    log_success "Port forwards configured"
    log_info "Grafana:    http://localhost:3000"
    log_info "Prometheus: http://localhost:9090"
}

##############################################################################
# Verification
##############################################################################

verify_installation() {
    log_section "Verifying Installation"

    log_info "Cluster nodes:"
    kubectl get nodes

    echo ""
    log_info "Monitoring stack pods:"
    kubectl get pods -n $NAMESPACE

    echo ""
    log_info "Storage classes:"
    kubectl get storageclass

    log_success "Installation verification complete"
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    local grafana_password=$(cat "$SCRIPT_DIR/grafana-password.txt" 2>/dev/null || echo "N/A")

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ DRC-IO AWS EKS Infrastructure Ready!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo "📊 Cluster Information:"
    echo "   Name:    $CLUSTER_NAME"
    echo "   Region:  $REGION"
    echo "   Version: 1.28"
    echo ""
    echo "🔗 Monitoring Access:"
    if [ "$MONITORING_READY" -eq 1 ]; then
        echo "   Grafana:    http://localhost:3000"
        echo "   Prometheus: http://localhost:9090"
        echo ""
        echo "🔐 Grafana Credentials:"
        echo "   Username: admin"
        echo "   Password: $grafana_password"
        echo "   (saved to: infrastructure/grafana-password.txt)"
    else
        echo "   Monitoring stack not installed. After running ./infrastructure/fix-ebs-csi.sh, rerun:" 
        echo "     helm upgrade --install prometheus prometheus-community/kube-prometheus-stack"
        echo "       -n monitoring -f kubernetes/monitoring/prometheus-values.yaml --wait --timeout 15m"
    fi
    echo ""
    echo "📝 Next Steps:"
    echo "   1. Build and push Docker images:"
    echo "      cd scripts && ./build-push.sh"
    echo ""
    echo "   2. Deploy workloads:"
    echo "      cd scripts && ./deploy-all.sh"
    echo ""
    echo "   3. Run experiments:"
    echo "      cd scripts && ./run-experiment.sh"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo "💡 Useful commands:"
    echo "   kubectl get nodes"
    echo "   kubectl get pods -A"
    echo "   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana"
    echo ""
    echo "🧹 To teardown everything:"
    echo "   cd infrastructure && ./cleanup.sh"
    echo ""
}

##############################################################################
# Cleanup on Error
##############################################################################

cleanup_on_error() {
    log_error "Setup failed! Check the error messages above."
    log_warning "You may need to manually clean up resources using ./cleanup.sh"
    exit 1
}

trap cleanup_on_error ERR

##############################################################################
# Main Execution
##############################################################################

main() {
    log_section "🚀 DRC-IO Demo Infrastructure Setup"

    check_prerequisites
    create_eks_cluster
    update_kubeconfig
    log_section "Ensuring EBS CSI Driver is ready"
    set +e
    "$SCRIPT_DIR/fix-ebs-csi.sh"
    FIX_STATUS=$?
    set -e
    if [ $FIX_STATUS -ne 0 ]; then
        log_warning "Automatic EBS CSI setup reported issues; continuing regardless."
    fi

    install_metrics_server
    set +e
    install_prometheus_stack
    INSTALL_STATUS=$?
    set -e
    if [ $INSTALL_STATUS -ne 0 ]; then
        log_warning "Monitoring stack installation failed (often due to the EBS CSI driver)."
        log_warning "Run ./infrastructure/fix-ebs-csi.sh, then rerun the monitoring install via:"
        log_warning "  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack"
        log_warning "    -n monitoring -f kubernetes/monitoring/prometheus-values.yaml --wait --timeout 15m"
    else
        MONITORING_READY=1
        setup_grafana_credentials
        setup_port_forwards
    fi
    verify_installation
    print_summary
}

# Run main function
main "$@"
