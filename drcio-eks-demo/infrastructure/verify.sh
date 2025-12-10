#!/bin/bash
##############################################################################
# DRC-IO System Health Check
#
# This script verifies that all components of the DRC-IO system are
# properly deployed and functioning correctly.
#
# Usage:
#   ./verify.sh [OPTIONS]
#
# Options:
#   --detailed    Show detailed status information
#   --json        Output results in JSON format
#   --help        Show this help message
##############################################################################

set -e
set -o pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DETAILED=false
JSON_OUTPUT=false
ERRORS=0
WARNINGS=0

##############################################################################
# Helper Functions
##############################################################################

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++))
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

##############################################################################
# Parse Arguments
##############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --detailed)
                DETAILED=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --detailed    Show detailed status information"
                echo "  --json        Output results in JSON format"
                echo "  --help, -h    Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

##############################################################################
# Health Checks
##############################################################################

check_cluster_connection() {
    log_section "1. Cluster Connection"

    if kubectl cluster-info &> /dev/null; then
        log_success "Connected to cluster"

        if [ "$DETAILED" = true ]; then
            local context=$(kubectl config current-context)
            local cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$context\")].context.cluster}")
            log_info "Context: $context"
            log_info "Cluster: $cluster"
        fi
    else
        log_error "Cannot connect to cluster"
        log_info "Run: aws eks update-kubeconfig --name drcio-demo --region us-east-1"
        return 1
    fi
}

check_nodes() {
    log_section "2. Node Status"

    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)

    if [ "$total_nodes" -eq 0 ]; then
        log_error "No nodes found"
        return 1
    fi

    if [ "$ready_nodes" -eq "$total_nodes" ]; then
        log_success "$ready_nodes/$total_nodes nodes ready"
    else
        log_warning "$ready_nodes/$total_nodes nodes ready"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get nodes -o wide
    fi
}

check_monitoring_stack() {
    log_section "3. Monitoring Stack"

    # Check Prometheus
    local prometheus_pods=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [ "$prometheus_pods" -gt 0 ]; then
        log_success "Prometheus running ($prometheus_pods pods)"
    else
        log_error "Prometheus not running"
    fi

    # Check Grafana
    local grafana_pods=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [ "$grafana_pods" -gt 0 ]; then
        log_success "Grafana running ($grafana_pods pods)"
    else
        log_error "Grafana not running"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get pods -n monitoring
    fi
}

check_drcio_controller() {
    log_section "4. DRC-IO Controller"

    # Check if DaemonSet exists
    if ! kubectl get daemonset drcio-controller &> /dev/null; then
        log_warning "DRC-IO controller not deployed"
        log_info "Run: cd scripts && ./deploy-all.sh"
        return 1
    fi

    # Check controller pods
    local desired=$(kubectl get daemonset drcio-controller -o jsonpath='{.status.desiredNumberScheduled}')
    local ready=$(kubectl get daemonset drcio-controller -o jsonpath='{.status.numberReady}')

    if [ "$ready" -eq "$desired" ] && [ "$desired" -gt 0 ]; then
        log_success "DRC-IO controller running ($ready/$desired pods)"
    elif [ "$desired" -eq 0 ]; then
        log_warning "DRC-IO controller scaled to 0"
    else
        log_warning "DRC-IO controller pods: $ready/$desired ready"
    fi

    # Check controller metrics
    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get pods -l app=drcio-controller -o wide

        # Try to fetch metrics
        local controller_pod=$(kubectl get pods -l app=drcio-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$controller_pod" ]; then
            echo ""
            log_info "Controller logs (last 5 lines):"
            kubectl logs "$controller_pod" --tail=5 2>/dev/null || echo "  (logs not available)"
        fi
    fi
}

check_workloads() {
    log_section "5. Workloads"

    # Check HP service
    if kubectl get deployment hp-gnn-service &> /dev/null; then
        local hp_desired=$(kubectl get deployment hp-gnn-service -o jsonpath='{.spec.replicas}')
        local hp_ready=$(kubectl get deployment hp-gnn-service -o jsonpath='{.status.readyReplicas}')

        if [ "$hp_ready" = "$hp_desired" ]; then
            log_success "HP GNN Service running ($hp_ready/$hp_desired replicas)"
        else
            log_warning "HP GNN Service: $hp_ready/$hp_desired replicas ready"
        fi
    else
        log_warning "HP GNN Service not deployed"
        log_info "Run: cd scripts && ./deploy-all.sh"
    fi

    # Check LP batch jobs
    local lp_jobs=$(kubectl get jobs -l app=lp-batch --no-headers 2>/dev/null | wc -l)

    if [ "$lp_jobs" -gt 0 ]; then
        local completed=$(kubectl get jobs -l app=lp-batch --no-headers 2>/dev/null | grep -c "1/1" || echo 0)
        log_info "LP Batch Jobs: $lp_jobs total, $completed completed"
    else
        log_info "No LP batch jobs currently running"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get pods -l 'app in (hp-gnn-service,lp-batch)' -o wide
    fi
}

check_services() {
    log_section "6. Services"

    # Check HP service
    if kubectl get svc hp-gnn-service &> /dev/null; then
        local svc_type=$(kubectl get svc hp-gnn-service -o jsonpath='{.spec.type}')
        local svc_ip=$(kubectl get svc hp-gnn-service -o jsonpath='{.spec.clusterIP}')

        log_success "HP GNN Service ($svc_type): $svc_ip"

        # Check LoadBalancer status
        if [ "$svc_type" = "LoadBalancer" ]; then
            local lb_hostname=$(kubectl get svc hp-gnn-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            local lb_ip=$(kubectl get svc hp-gnn-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

            if [ -n "$lb_hostname" ]; then
                log_info "External: http://$lb_hostname"
            elif [ -n "$lb_ip" ]; then
                log_info "External: http://$lb_ip"
            else
                log_warning "LoadBalancer pending (still provisioning)"
            fi
        fi
    else
        log_warning "HP GNN Service not found"
    fi

    # Check DRC-IO controller service
    if kubectl get svc drcio-controller-metrics &> /dev/null; then
        log_success "DRC-IO Controller metrics service available"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get svc
    fi
}

check_endpoints() {
    log_section "7. Endpoint Accessibility"

    # Check Grafana
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null | grep -q "200\|302"; then
        log_success "Grafana: http://localhost:3000"
    else
        log_warning "Grafana not accessible at http://localhost:3000"
        log_info "Run: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    fi

    # Check Prometheus
    if curl -s http://localhost:9090/-/healthy 2>/dev/null | grep -q "Prometheus"; then
        log_success "Prometheus: http://localhost:9090"
    else
        log_warning "Prometheus not accessible at http://localhost:9090"
        log_info "Run: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
    fi

    # Check if HP service is accessible (if LoadBalancer exists)
    local lb_hostname=$(kubectl get svc hp-gnn-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -n "$lb_hostname" ]; then
        if curl -s -o /dev/null -w "%{http_code}" "http://$lb_hostname/health" 2>/dev/null | grep -q "200"; then
            log_success "HP GNN Service: http://$lb_hostname"
        else
            log_warning "HP GNN Service not yet accessible via LoadBalancer"
        fi
    fi
}

check_storage() {
    log_section "8. Storage"

    # Check StorageClasses
    local storage_classes=$(kubectl get storageclass --no-headers 2>/dev/null | wc -l)

    if [ "$storage_classes" -gt 0 ]; then
        log_success "$storage_classes StorageClass(es) configured"
    else
        log_warning "No StorageClasses found"
    fi

    # Check PVCs
    local pvcs=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)

    if [ "$pvcs" -gt 0 ]; then
        local bound=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Bound" || echo 0)
        log_info "$bound/$pvcs PVCs bound"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get storageclass
        echo ""
        kubectl get pvc -A
    fi
}

check_metrics() {
    log_section "9. Metrics Collection"

    # Check if Prometheus is scraping targets
    if curl -s http://localhost:9090/api/v1/targets 2>/dev/null | grep -q "\"health\":\"up\""; then
        log_success "Prometheus scraping targets"
    else
        log_warning "Prometheus may not be scraping targets properly"
    fi

    # Check for DRC-IO metrics
    if curl -s http://localhost:9090/api/v1/query?query=drcio_io_weight 2>/dev/null | grep -q "\"status\":\"success\""; then
        log_success "DRC-IO metrics available"
    else
        log_info "DRC-IO metrics not yet available (controller may be starting)"
    fi

    # Check for GNN service metrics
    if curl -s http://localhost:9090/api/v1/query?query=gnn_requests_total 2>/dev/null | grep -q "\"status\":\"success\""; then
        log_success "GNN service metrics available"
    else
        log_info "GNN service metrics not yet available"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        log_info "Recent DRC-IO metrics:"
        curl -s http://localhost:9090/api/v1/query?query=drcio_active_pods 2>/dev/null | \
            jq -r '.data.result[] | "  Priority: \(.metric.priority), Count: \(.value[1])"' 2>/dev/null || \
            echo "  (not available)"
    fi
}

check_rbac() {
    log_section "10. RBAC Permissions"

    # Check ServiceAccount
    if kubectl get serviceaccount drcio-controller &> /dev/null; then
        log_success "ServiceAccount configured"
    else
        log_warning "ServiceAccount not found"
    fi

    # Check ClusterRole
    if kubectl get clusterrole drcio-controller &> /dev/null; then
        log_success "ClusterRole configured"
    else
        log_warning "ClusterRole not found"
    fi

    # Check ClusterRoleBinding
    if kubectl get clusterrolebinding drcio-controller &> /dev/null; then
        log_success "ClusterRoleBinding configured"
    else
        log_warning "ClusterRoleBinding not found"
    fi

    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl auth can-i list pods --as=system:serviceaccount:default:drcio-controller && \
            log_info "Controller can list pods" || \
            log_warning "Controller cannot list pods"

        kubectl auth can-i get nodes --as=system:serviceaccount:default:drcio-controller && \
            log_info "Controller can get nodes" || \
            log_warning "Controller cannot get nodes"
    fi
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    log_section "Health Check Summary"

    echo ""
    if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        echo -e "${GREEN}✓ All checks passed!${NC}"
        echo ""
        echo "Your DRC-IO system is healthy and ready to use."
        echo ""
        echo "Next steps:"
        echo "  - Access Grafana: http://localhost:3000"
        echo "  - Run experiments: cd scripts && ./run-experiment.sh"
        echo "  - View logs: kubectl logs -l app=drcio-controller"
    elif [ "$ERRORS" -eq 0 ]; then
        echo -e "${YELLOW}System operational with $WARNINGS warning(s)${NC}"
        echo ""
        echo "Some components may not be fully deployed or accessible."
        echo "Review warnings above and take corrective action if needed."
    else
        echo -e "${RED}Found $ERRORS error(s) and $WARNINGS warning(s)${NC}"
        echo ""
        echo "Please address the errors above before proceeding."
        echo ""
        echo "Common fixes:"
        echo "  - Run infrastructure setup: cd infrastructure && ./setup.sh"
        echo "  - Deploy workloads: cd scripts && ./deploy-all.sh"
        echo "  - Setup port forwarding: kubectl port-forward ..."
    fi

    echo ""
    log_info "For detailed status: $0 --detailed"
}

print_json_output() {
    cat <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "cluster": "$(kubectl config current-context 2>/dev/null || echo 'unknown')",
  "errors": $ERRORS,
  "warnings": $WARNINGS,
  "status": $([ "$ERRORS" -eq 0 ] && echo '"healthy"' || echo '"unhealthy"')
}
EOF
}

##############################################################################
# Main Execution
##############################################################################

main() {
    parse_args "$@"

    if [ "$JSON_OUTPUT" = false ]; then
        log_section "DRC-IO System Health Check"
        echo ""
    fi

    # Run all checks
    check_cluster_connection
    check_nodes
    check_monitoring_stack
    check_drcio_controller
    check_workloads
    check_services
    check_endpoints
    check_storage
    check_metrics
    check_rbac

    # Print summary
    if [ "$JSON_OUTPUT" = true ]; then
        print_json_output
    else
        print_summary
    fi

    # Exit with appropriate code
    [ "$ERRORS" -eq 0 ] && exit 0 || exit 1
}

# Run main function
main "$@"
