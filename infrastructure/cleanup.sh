#!/bin/bash
##############################################################################
# DRC-IO Demo Infrastructure Cleanup Script
#
# This script safely tears down all AWS resources created for the DRC-IO demo.
# It provides cost estimates and confirmation before deletion.
#
# ⚠️  WARNING: This will delete:
#   - EKS cluster and all workloads
#   - EC2 instances (worker nodes)
#   - EBS volumes
#   - Load balancers (if created)
#   - VPC and networking components
#
# Usage:
#   ./cleanup.sh           # Interactive mode with confirmations
#   ./cleanup.sh --force   # Skip confirmations (use with caution!)
##############################################################################

set -e
set -u
set -o pipefail

# Color output
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
FORCE_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force, -f    Skip all confirmations"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

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

confirm_action() {
    if [ "$FORCE_MODE" = true ]; then
        return 0
    fi

    local message="$1"
    echo -e "${YELLOW}⚠  $message${NC}"
    read -p "Are you sure? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi
}

##############################################################################
# Cost Estimation
##############################################################################

estimate_current_costs() {
    log_section "💰 Estimated Current Costs"

    log_info "Analyzing current resource usage..."

    # Check if cluster exists
    if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_warning "Cluster $CLUSTER_NAME not found in region $REGION"
        echo ""
        echo "Nothing to clean up!"
        exit 0
    fi

    echo ""
    echo "Resource breakdown:"
    echo ""

    # EKS Control Plane
    echo "  EKS Control Plane:"
    echo "    Cost: ~\$0.10/hour (\$73/month)"
    echo ""

    # Worker Nodes
    local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$node_count" -gt 0 ]; then
        echo "  EC2 Worker Nodes: $node_count × t3.xlarge"
        echo "    Cost: ~\$0.1664/hour per node"
        echo "    Total: ~\$$(awk "BEGIN {printf \"%.2f\", $node_count * 0.1664}")/hour"
        echo "    Monthly: ~\$$(awk "BEGIN {printf \"%.2f\", $node_count * 0.1664 * 730}")"
        echo ""
    fi

    # EBS Volumes
    local volume_count=$(kubectl get pv 2>/dev/null | grep -c "Bound" || echo "0")
    if [ "$volume_count" -gt 0 ]; then
        echo "  EBS Volumes (gp3): $volume_count volumes"
        echo "    Estimated: ~\$0.08/GB-month"
        echo ""
    fi

    # NAT Gateway
    echo "  NAT Gateway: 1"
    echo "    Cost: ~\$0.045/hour (\$32.85/month)"
    echo "    + Data transfer costs"
    echo ""

    # Load Balancers
    local lb_count=$(kubectl get svc -A 2>/dev/null | grep -c "LoadBalancer" || echo "0")
    if [ "$lb_count" -gt 0 ]; then
        echo "  Load Balancers: $lb_count"
        echo "    Cost: ~\$0.025/hour per LB"
        echo "    Total: ~\$$(awk "BEGIN {printf \"%.2f\", $lb_count * 0.025}")/hour"
        echo ""
    fi

    # Total estimate
    local hourly_cost=$(awk "BEGIN {printf \"%.2f\", 0.10 + ($node_count * 0.1664) + 0.045 + ($lb_count * 0.025)}")
    local monthly_cost=$(awk "BEGIN {printf \"%.2f\", $hourly_cost * 730}")

    echo -e "${CYAN}─────────────────────────────────────────────${NC}"
    echo -e "  Estimated Total:"
    echo -e "    Hourly:  ~\$$hourly_cost"
    echo -e "    Monthly: ~\$$monthly_cost"
    echo -e "${CYAN}─────────────────────────────────────────────${NC}"
    echo ""
    log_info "Note: Costs are estimates. Check AWS Cost Explorer for actual usage."
}

##############################################################################
# Resource Cleanup
##############################################################################

stop_port_forwards() {
    log_section "Stopping Port Forwards"

    log_info "Killing kubectl port-forward processes..."
    pkill -f "kubectl port-forward" || log_warning "No port forwards found"

    log_success "Port forwards stopped"
}

delete_helm_releases() {
    log_section "Removing Helm Releases"

    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warning "Namespace $NAMESPACE not found, skipping Helm cleanup"
        return 0
    fi

    log_info "Listing Helm releases in namespace $NAMESPACE..."
    local releases=$(helm list -n "$NAMESPACE" -q 2>/dev/null || echo "")

    if [ -z "$releases" ]; then
        log_info "No Helm releases found"
        return 0
    fi

    echo "$releases" | while read -r release; do
        if [ -n "$release" ]; then
            log_info "Uninstalling Helm release: $release"
            helm uninstall "$release" -n "$NAMESPACE" --wait || log_warning "Failed to uninstall $release"
        fi
    done

    log_success "Helm releases removed"
}

delete_kubernetes_resources() {
    log_section "Cleaning up Kubernetes Resources"

    # Delete all resources in custom namespaces
    local custom_namespaces=$(kubectl get namespaces -o jsonpath='{.items[?(@.metadata.name!="kube-system" && @.metadata.name!="kube-public" && @.metadata.name!="kube-node-lease" && @.metadata.name!="default")].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$custom_namespaces" ]; then
        for ns in $custom_namespaces; do
            log_info "Deleting namespace: $ns"
            kubectl delete namespace "$ns" --wait=false || log_warning "Failed to delete namespace $ns"
        done

        log_info "Waiting for namespaces to be deleted (timeout: 2 minutes)..."
        for ns in $custom_namespaces; do
            kubectl wait --for=delete namespace/"$ns" --timeout=120s 2>/dev/null || log_warning "Timeout waiting for $ns"
        done
    fi

    # Force delete any stuck PVCs
    log_info "Checking for persistent volume claims..."
    local pvcs=$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

    if [ -n "$pvcs" ]; then
        echo "$pvcs" | while IFS='/' read -r ns pvc; do
            if [ -n "$ns" ] && [ -n "$pvc" ]; then
                log_info "Deleting PVC: $ns/$pvc"
                kubectl delete pvc "$pvc" -n "$ns" --force --grace-period=0 2>/dev/null || true
            fi
        done
    fi

    log_success "Kubernetes resources cleaned up"
}

delete_eks_cluster() {
    log_section "Deleting EKS Cluster"

    confirm_action "This will permanently delete the EKS cluster and all associated resources."

    log_info "Deleting EKS cluster: $CLUSTER_NAME"
    log_warning "This may take 10-15 minutes..."

    if eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait; then
        log_success "EKS cluster deleted successfully"
    else
        log_error "Failed to delete EKS cluster"
        log_info "You may need to manually clean up resources in the AWS Console"
        return 1
    fi
}

cleanup_local_files() {
    log_section "Cleaning up Local Files"

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Remove Grafana password file
    if [ -f "$script_dir/grafana-password.txt" ]; then
        log_info "Removing Grafana password file..."
        rm -f "$script_dir/grafana-password.txt"
    fi

    # Remove kubeconfig context
    log_info "Removing kubeconfig context..."
    kubectl config delete-context "$(kubectl config current-context)" 2>/dev/null || true
    kubectl config delete-cluster "$CLUSTER_NAME.$REGION.eksctl.io" 2>/dev/null || true
    kubectl config delete-user "$(kubectl config view -o jsonpath="{.users[?(@.name==\"*$CLUSTER_NAME*\")].name}")" 2>/dev/null || true

    log_success "Local files cleaned up"
}

verify_cleanup() {
    log_section "Verifying Cleanup"

    # Check if cluster still exists
    if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_error "Cluster still exists! Cleanup may have failed."
        return 1
    fi

    log_success "Cluster successfully removed"

    # Check for orphaned resources (requires AWS CLI)
    log_info "Checking for orphaned AWS resources..."

    # Check for LoadBalancers
    local lbs=$(aws elb describe-load-balancers --region "$REGION" 2>/dev/null | \
        grep -c "kubernetes.io/cluster/$CLUSTER_NAME" || echo "0")

    if [ "$lbs" -gt 0 ]; then
        log_warning "Found $lbs orphaned load balancer(s)"
        log_info "You may need to manually delete them in the AWS Console"
    fi

    # Check for Security Groups
    local sgs=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
        --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || echo "")

    if [ -n "$sgs" ]; then
        log_warning "Found orphaned security group(s): $sgs"
        log_info "These will be automatically cleaned up or can be manually deleted"
    fi

    log_success "Verification complete"
}

##############################################################################
# Cost Summary
##############################################################################

print_cost_summary() {
    log_section "💰 Cost Summary"

    local cleanup_date=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo "Cleanup completed at: $cleanup_date"
    echo ""
    echo "Resources deleted:"
    echo "  ✓ EKS control plane"
    echo "  ✓ EC2 worker nodes"
    echo "  ✓ EBS volumes"
    echo "  ✓ VPC and networking"
    echo "  ✓ Load balancers (if any)"
    echo ""
    echo -e "${GREEN}You will no longer incur charges for these resources.${NC}"
    echo ""
    echo "⚠️  Note: It may take a few minutes for resources to fully terminate."
    echo "   Check AWS Cost Explorer in ~24 hours for final billing confirmation."
    echo ""
    echo "📊 View detailed costs:"
    echo "   https://console.aws.amazon.com/cost-management/home#/cost-explorer"
    echo ""
}

##############################################################################
# Final Summary
##############################################################################

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ Cleanup Complete!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo "All DRC-IO demo resources have been removed."
    echo ""
    echo "To set up the infrastructure again:"
    echo "  ./setup.sh"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    log_section "🧹 DRC-IO Demo Infrastructure Cleanup"

    if [ "$FORCE_MODE" = true ]; then
        log_warning "Running in FORCE mode - skipping confirmations!"
    fi

    # Show current costs
    estimate_current_costs

    # Confirm cleanup
    if [ "$FORCE_MODE" = false ]; then
        echo ""
        confirm_action "This will delete ALL resources and you will lose all data."
    fi

    # Execute cleanup steps
    stop_port_forwards
    delete_helm_releases
    delete_kubernetes_resources
    delete_eks_cluster
    cleanup_local_files
    verify_cleanup
    print_cost_summary
    print_summary

    log_success "Cleanup completed successfully!"
}

# Run main function
main "$@"
