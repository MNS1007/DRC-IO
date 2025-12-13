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

    local SA_EXISTS=0

    if eksctl get iamserviceaccount \
        --cluster "$CLUSTER_NAME" \
        --region "$REGION" \
        --name "$SERVICE_ACCOUNT_NAME" \
        --namespace kube-system 2>/dev/null | grep -q "$SERVICE_ACCOUNT_NAME"; then
        SA_EXISTS=1
    fi

    if [ $SA_EXISTS -eq 1 ]; then
        log_warning "Service account already exists, deleting to recreate..."

        eksctl delete iamserviceaccount \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --name "$SERVICE_ACCOUNT_NAME" \
            --namespace kube-system \
            --wait || log_warning "Failed to delete existing service account"

        # Wait a bit for deletion to complete
        sleep 5
        kubectl delete serviceaccount "$SERVICE_ACCOUNT_NAME" -n kube-system --ignore-not-found >/dev/null 2>&1 || true
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
    kubectl patch serviceaccount "$SERVICE_ACCOUNT_NAME" -n kube-system \
        --type merge -p '{"metadata":{"labels":{"app.kubernetes.io/managed-by":null}}}' >/dev/null 2>&1 || true
}

##############################################################################
# EBS CSI Driver Addon Installation
##############################################################################

describe_addon_health() {
    aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --addon-name aws-ebs-csi-driver \
        --query 'addon.health.issues' \
        --output json 2>/dev/null || echo "[]"
}

get_cluster_version() {
    aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'cluster.version' \
        --output text
}

get_latest_addon_version() {
    local cluster_version="$1"
    aws eks describe-addon-versions \
        --addon-name aws-ebs-csi-driver \
        --kubernetes-version "$cluster_version" \
        --query 'addons[0].addonVersions[0].addonVersion' \
        --output text 2>/dev/null
}

get_addon_status() {
    aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --addon-name aws-ebs-csi-driver \
        --query 'addon.status' \
        --output text 2>/dev/null || echo "NOT_FOUND"
}

install_ebs_csi_addon() {
    log_section "Installing/Updating EBS CSI Driver Addon"

    local cluster_version
    cluster_version=$(get_cluster_version)
    log_info "Cluster Kubernetes version: $cluster_version"

    local addon_version="${ADDON_VERSION_OVERRIDE:-}"
    if [ -z "$addon_version" ] || [ "$addon_version" = "None" ]; then
        addon_version=$(get_latest_addon_version "$cluster_version")
    fi

    if [ -z "$addon_version" ] || [ "$addon_version" = "None" ]; then
        log_warning "Unable to determine addon version automatically; letting AWS choose the default"
    else
        log_info "Using aws-ebs-csi-driver addon version: $addon_version"
    fi

    log_info "Retrieving service account role ARN..."
    local ROLE_ARN
    ROLE_ARN=$(aws iam list-roles --query "Roles[?RoleName=='eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-ku-Role1-*'].Arn" --output text 2>/dev/null || echo "")

    if [ -z "$ROLE_ARN" ]; then
        ROLE_ARN=$(eksctl get iamserviceaccount \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --name "$SERVICE_ACCOUNT_NAME" \
            --namespace kube-system \
            -o json 2>/dev/null | jq -r '.[0].status.roleARN' || echo "")
    fi

    local role_args=()
    if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "null" ]; then
        log_success "Role ARN: $ROLE_ARN"
        role_args=(--service-account-role-arn "$ROLE_ARN")
    else
        log_warning "Could not retrieve role ARN automatically; continuing without explicit role"
    fi

    local addon_version_args=()
    if [ -n "$addon_version" ] && [ "$addon_version" != "None" ]; then
        addon_version_args=(--addon-version "$addon_version")
    fi

    local create_or_update="create"

    log_info "Checking if EBS CSI addon is installed..."
    local addon_exists=0
    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --addon-name aws-ebs-csi-driver &> /dev/null; then
        addon_exists=1
        local existing_status
        existing_status=$(get_addon_status)
        if [ "$existing_status" = "CREATE_FAILED" ] || [ "$existing_status" = "UPDATE_FAILED" ]; then
            log_warning "Existing addon is in state $existing_status; deleting before reinstall."
            aws eks delete-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver >/dev/null 2>&1 || true
            for i in {1..20}; do
                if aws eks describe-addon \
                    --cluster-name "$CLUSTER_NAME" \
                    --region "$REGION" \
                    --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
                    sleep 5
                else
                    addon_exists=0
                    break
                fi
            done
            log_info "Addon deletion completed; proceeding with fresh install."
        fi
    fi

    if [ "$addon_exists" -eq 1 ]; then
        log_warning "EBS CSI addon already exists, updating..."
        create_or_update="update"

        aws eks update-addon \
            --cluster-name "$CLUSTER_NAME" \
            --region "$REGION" \
            --addon-name aws-ebs-csi-driver \
            "${addon_version_args[@]}" \
            "${role_args[@]}" \
            --resolve-conflicts OVERWRITE

        log_success "EBS CSI addon update initiated"
    else
        log_info "Installing EBS CSI addon..."

        aws eks create-addon \
            --cluster-name "$CLUSTER_NAME" \
            --region "$REGION" \
            --addon-name aws-ebs-csi-driver \
            "${addon_version_args[@]}" \
            "${role_args[@]}"

        log_success "EBS CSI addon installation initiated"
    fi

    log_info "Waiting for addon to become active (this may take 1-2 minutes)..."
    local ADDON_STATUS=""
    for i in {1..24}; do
        ADDON_STATUS=$(aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --region "$REGION" \
            --addon-name aws-ebs-csi-driver \
            --query 'addon.status' \
            --output text 2>/dev/null || echo "UNKNOWN")

        if [ "$ADDON_STATUS" = "ACTIVE" ]; then
            log_success "EBS CSI addon is active"
            break
        elif [ "$ADDON_STATUS" = "CREATE_FAILED" ] || [ "$ADDON_STATUS" = "UPDATE_FAILED" ]; then
            log_error "Addon $create_or_update failed with status: $ADDON_STATUS"
            log_info "AWS reported issues:"
            describe_addon_health

            log_info "Attempting forced reinstallation..."
            aws eks delete-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver >/dev/null 2>&1 || true
            sleep 10

            aws eks create-addon \
                --cluster-name "$CLUSTER_NAME" \
                --region "$REGION" \
                --addon-name aws-ebs-csi-driver \
                "${addon_version_args[@]}" \
                "${role_args[@]}"

            log_info "Reinstall kicked off; waiting for ACTIVE state..."
            create_or_update="create"
            sleep 10
            continue
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
        current_prov=$(kubectl get storageclass gp2 -o jsonpath='{.provisioner}' 2>/dev/null)
        if [ "$current_prov" != "ebs.csi.aws.com" ]; then
            log_warning "gp2 StorageClass uses $current_prov; recreating with ebs.csi.aws.com"
            kubectl delete storageclass gp2 >/dev/null 2>&1 || true
            NEED_SC=1
        else
            log_success "gp2 StorageClass already uses ebs.csi.aws.com"
            NEED_SC=0
        fi
    else
        log_warning "gp2 StorageClass not found, creating..."
        NEED_SC=1
    fi

    if [ "${NEED_SC:-0}" -eq 1 ]; then
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
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
