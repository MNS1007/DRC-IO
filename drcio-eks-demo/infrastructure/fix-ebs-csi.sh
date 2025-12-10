#!/bin/bash
##############################################################################
# EBS CSI Driver Fix Script for DRC-IO Demo
#
# This script resolves the common issue where Prometheus/Grafana pods are
# stuck in "Pending" state due to missing EBS CSI driver permissions.
#
# What this script does:
#   1. Creates IAM OIDC provider for the cluster
#   2. Creates IAM service account for EBS CSI driver
#   3. Installs/updates aws-ebs-csi-driver addon
#   4. Verifies the EBS CSI driver is working
#   5. Restarts stuck pods to mount volumes
#
# Usage:
#   ./fix-ebs-csi.sh
##############################################################################

set -e
set -u
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CLUSTER_NAME="drcio-demo"
REGION="us-east-1"
NAMESPACE="monitoring"
SERVICE_ACCOUNT_NAME="ebs-csi-controller-sa"
POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

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
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
}

##############################################################################
# Pre-flight Checks
##############################################################################

check_prerequisites() {
    log_section "Checking Prerequisites"

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        exit 1
    fi
    log_success "AWS CLI found: $(aws --version | head -n1)"

    # Check eksctl
    if ! command -v eksctl &> /dev/null; then
        log_error "eksctl not found"
        exit 1
    fi
    log_success "eksctl found: $(eksctl version)"

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    log_success "kubectl found"

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_info "Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION"
        exit 1
    fi
    log_success "Connected to cluster: $CLUSTER_NAME"

    # Get AWS account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_info "AWS Account ID: $AWS_ACCOUNT_ID"
}

##############################################################################
# OIDC Provider Setup
##############################################################################

setup_oidc_provider() {
    log_section "Setting up IAM OIDC Provider"

    log_info "Checking if OIDC provider exists..."

    # Get cluster's OIDC issuer URL
    OIDC_ISSUER=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --query "cluster.identity.oidc.issuer" \
        --output text)

    if [ -z "$OIDC_ISSUER" ]; then
        log_error "Could not retrieve OIDC issuer from cluster"
        exit 1
    fi

    log_info "OIDC Issuer: $OIDC_ISSUER"

    # Extract OIDC ID from issuer URL
    OIDC_ID=$(echo "$OIDC_ISSUER" | sed 's|https://||')

    # Check if OIDC provider already exists
    if aws iam list-open-id-connect-providers | grep -q "$OIDC_ID"; then
        log_success "OIDC provider already exists"
    else
        log_info "Creating OIDC provider..."

        eksctl utils associate-iam-oidc-provider \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --approve

        log_success "OIDC provider created"
    fi
}

##############################################################################
# IAM Service Account Setup
##############################################################################

create_service_account() {
    log_section "Creating IAM Service Account for EBS CSI Driver"

    log_info "Checking if service account exists..."

    # Check if service account already exists
    if eksctl get iamserviceaccount \
        --cluster "$CLUSTER_NAME" \
        --region "$REGION" \
        --name "$SERVICE_ACCOUNT_NAME" \
        --namespace kube-system 2>/dev/null | grep -q "$SERVICE_ACCOUNT_NAME"; then

        log_warning "Service account already exists, deleting to recreate..."

        eksctl delete iamserviceaccount \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --name "$SERVICE_ACCOUNT_NAME" \
            --namespace kube-system \
            --wait || log_warning "Failed to delete existing service account"

        # Wait a bit for deletion to complete
        sleep 5
    fi

    log_info "Creating IAM service account with EBS CSI driver policy..."

    eksctl create iamserviceaccount \
        --cluster "$CLUSTER_NAME" \
        --region "$REGION" \
        --name "$SERVICE_ACCOUNT_NAME" \
        --namespace kube-system \
        --attach-policy-arn "$POLICY_ARN" \
        --approve \
        --override-existing-serviceaccounts

    log_success "IAM service account created"
}

##############################################################################
# EBS CSI Driver Addon Installation
##############################################################################

install_ebs_csi_addon() {
    log_section "Installing/Updating EBS CSI Driver Addon"

    # Get service account role ARN
    log_info "Retrieving service account role ARN..."

    ROLE_ARN=$(aws iam list-roles --query "Roles[?RoleName=='eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-ku-Role1-*'].Arn" --output text 2>/dev/null || echo "")

    if [ -z "$ROLE_ARN" ]; then
        # Try alternate method
        ROLE_ARN=$(eksctl get iamserviceaccount \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --name "$SERVICE_ACCOUNT_NAME" \
            --namespace kube-system \
            -o json 2>/dev/null | jq -r '.[0].status.roleARN' || echo "")
    fi

    if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "null" ]; then
        log_warning "Could not retrieve role ARN automatically"
        log_info "Installing addon without explicit role ARN..."
    else
        log_success "Role ARN: $ROLE_ARN"
    fi

    # Check if addon already exists
    log_info "Checking if EBS CSI addon is installed..."

    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --addon-name aws-ebs-csi-driver &> /dev/null; then

        log_warning "EBS CSI addon already exists, updating..."

        if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "null" ]; then
            aws eks update-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver \
                --service-account-role-arn "$ROLE_ARN" \
                --resolve-conflicts OVERWRITE
        else
            aws eks update-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver \
                --resolve-conflicts OVERWRITE
        fi

        log_success "EBS CSI addon updated"
    else
        log_info "Installing EBS CSI addon..."

        if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "null" ]; then
            aws eks create-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver \
                --service-account-role-arn "$ROLE_ARN"
        else
            aws eks create-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver
        fi

        log_success "EBS CSI addon installed"
    fi

    # Wait for addon to be active
    log_info "Waiting for addon to become active (this may take 1-2 minutes)..."

    for i in {1..24}; do
        ADDON_STATUS=$(aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --region "$REGION" \
            --addon-name aws-ebs-csi-driver \
            --query 'addon.status' \
            --output text)

        if [ "$ADDON_STATUS" = "ACTIVE" ]; then
            log_success "EBS CSI addon is active"
            break
        elif [ "$ADDON_STATUS" = "CREATE_FAILED" ] || [ "$ADDON_STATUS" = "UPDATE_FAILED" ]; then
            log_error "Addon installation/update failed with status: $ADDON_STATUS"
            exit 1
        else
            echo -n "."
            sleep 5
        fi
    done

    if [ "$ADDON_STATUS" != "ACTIVE" ]; then
        log_warning "Addon status: $ADDON_STATUS (may still be initializing)"
    fi
}

##############################################################################
# Verify EBS CSI Driver
##############################################################################

verify_ebs_csi_driver() {
    log_section "Verifying EBS CSI Driver"

    log_info "Checking EBS CSI controller pods..."

    # Wait for EBS CSI controller to be ready
    sleep 10

    if kubectl get pods -n kube-system -l app=ebs-csi-controller &> /dev/null; then
        log_success "EBS CSI controller pods found"

        # Show pod status
        kubectl get pods -n kube-system -l app=ebs-csi-controller

        # Wait for pods to be ready
        log_info "Waiting for EBS CSI controller pods to be ready..."

        if kubectl wait --for=condition=Ready pod \
            -l app=ebs-csi-controller \
            -n kube-system \
            --timeout=120s 2>/dev/null; then
            log_success "EBS CSI controller pods are ready"
        else
            log_warning "EBS CSI controller pods may not be fully ready yet"
        fi
    else
        log_warning "EBS CSI controller pods not found (may still be creating)"
    fi

    # Check EBS CSI node pods
    log_info "Checking EBS CSI node pods..."

    if kubectl get pods -n kube-system -l app=ebs-csi-node &> /dev/null; then
        log_success "EBS CSI node pods found"
        kubectl get pods -n kube-system -l app=ebs-csi-node
    else
        log_warning "EBS CSI node pods not found"
    fi

    # Verify StorageClass
    log_info "Checking for gp2 StorageClass..."

    if kubectl get storageclass gp2 &> /dev/null; then
        log_success "gp2 StorageClass exists"
    else
        log_warning "gp2 StorageClass not found, creating..."

        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp2
  fsType: ext4
EOF

        log_success "gp2 StorageClass created"
    fi
}

##############################################################################
# Restart Stuck Pods
##############################################################################

restart_stuck_pods() {
    log_section "Restarting Stuck Prometheus/Grafana Pods"

    # Check if monitoring namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warning "Namespace $NAMESPACE does not exist"
        log_info "Skipping pod restart"
        return
    fi

    log_info "Finding stuck pods in $NAMESPACE namespace..."

    # Get pending pods
    PENDING_PODS=$(kubectl get pods -n "$NAMESPACE" \
        --field-selector=status.phase=Pending \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$PENDING_PODS" ]; then
        log_info "No pending pods found"
    else
        log_info "Found pending pods: $PENDING_PODS"

        for pod in $PENDING_PODS; do
            log_info "Deleting pod: $pod"
            kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        done

        log_success "Pending pods deleted (will be recreated automatically)"
    fi

    # Also restart StatefulSets (Prometheus)
    log_info "Restarting Prometheus StatefulSet..."

    if kubectl get statefulset prometheus-kube-prometheus-prometheus -n "$NAMESPACE" &> /dev/null; then
        kubectl rollout restart statefulset/prometheus-kube-prometheus-prometheus -n "$NAMESPACE" || log_warning "Could not restart Prometheus"
    fi

    # Restart Grafana Deployment
    log_info "Restarting Grafana Deployment..."

    if kubectl get deployment prometheus-grafana -n "$NAMESPACE" &> /dev/null; then
        kubectl rollout restart deployment/prometheus-grafana -n "$NAMESPACE" || log_warning "Could not restart Grafana"
    fi

    # Wait for pods to be ready
    log_info "Waiting for pods to become ready (this may take 2-3 minutes)..."

    sleep 15

    # Wait for Prometheus
    if kubectl get statefulset prometheus-kube-prometheus-prometheus -n "$NAMESPACE" &> /dev/null; then
        log_info "Waiting for Prometheus pods..."
        if kubectl wait --for=condition=Ready pod \
            -l app.kubernetes.io/name=prometheus \
            -n "$NAMESPACE" \
            --timeout=180s 2>/dev/null; then
            log_success "Prometheus pods are ready"
        else
            log_warning "Prometheus pods may not be fully ready yet"
        fi
    fi

    # Wait for Grafana
    if kubectl get deployment prometheus-grafana -n "$NAMESPACE" &> /dev/null; then
        log_info "Waiting for Grafana pods..."
        if kubectl wait --for=condition=Ready pod \
            -l app.kubernetes.io/name=grafana \
            -n "$NAMESPACE" \
            --timeout=180s 2>/dev/null; then
            log_success "Grafana pods are ready"
        else
            log_warning "Grafana pods may not be fully ready yet"
        fi
    fi
}

##############################################################################
# Verification
##############################################################################

verify_deployment() {
    log_section "Final Verification"

    echo ""
    log_info "Monitoring namespace pods:"
    kubectl get pods -n "$NAMESPACE"

    echo ""
    log_info "PersistentVolumeClaims:"
    kubectl get pvc -n "$NAMESPACE"

    echo ""
    log_info "PersistentVolumes:"
    kubectl get pv

    # Check for any remaining pending pods
    PENDING_COUNT=$(kubectl get pods -n "$NAMESPACE" \
        --field-selector=status.phase=Pending \
        --no-headers 2>/dev/null | wc -l)

    if [ "$PENDING_COUNT" -gt 0 ]; then
        log_warning "$PENDING_COUNT pod(s) still pending"
        echo ""
        log_info "Pending pod details:"
        kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending
        echo ""
        log_info "Check pod events for details:"
        echo "  kubectl describe pods -n $NAMESPACE <pod-name>"
    else
        log_success "No pending pods found"
    fi
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    log_section "✅ EBS CSI Driver Fix Complete"

    echo ""
    echo "Summary of actions taken:"
    echo "  ✓ IAM OIDC provider configured"
    echo "  ✓ IAM service account created for EBS CSI driver"
    echo "  ✓ EBS CSI driver addon installed/updated"
    echo "  ✓ Stuck pods restarted"
    echo ""
    echo "Next steps:"
    echo "  1. Verify all pods are running:"
    echo "     kubectl get pods -n $NAMESPACE"
    echo ""
    echo "  2. Check PVC status:"
    echo "     kubectl get pvc -n $NAMESPACE"
    echo ""
    echo "  3. If issues persist, check pod events:"
    echo "     kubectl describe pod <pod-name> -n $NAMESPACE"
    echo ""
    echo "  4. Verify EBS CSI driver logs:"
    echo "     kubectl logs -n kube-system -l app=ebs-csi-controller"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    log_section "🔧 Fixing EBS CSI Driver for DRC-IO Demo"

    check_prerequisites
    setup_oidc_provider
    create_service_account
    install_ebs_csi_addon
    verify_ebs_csi_driver
    restart_stuck_pods
    verify_deployment
    print_summary

    log_success "EBS CSI driver fix completed successfully!"
}

# Run main function
main "$@"
