#!/bin/bash
##############################################################################
# DRC-IO Experiment Runner
#
# This script runs experiments to demonstrate DRC-IO's effectiveness in
# prioritizing I/O resources. It generates load on both high-priority and
# low-priority workloads while collecting metrics.
#
# Experiment scenarios:
#   1. Baseline: HP service only
#   2. Contention: HP service + LP batch job
#   3. DRC-IO enabled: HP service + LP batch job with I/O prioritization
#
# Usage:
#   ./run-experiment.sh [OPTIONS]
#
# Options:
#   --duration SECONDS    Experiment duration (default: 300)
#   --scenario NAME       Run specific scenario (baseline|contention|drcio)
#   --load-level LEVEL    Load level (low|medium|high)
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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
DURATION=300  # 5 minutes
SCENARIO="all"
LOAD_LEVEL="medium"
OUTPUT_DIR="$PROJECT_ROOT/results/$(date +%Y%m%d-%H%M%S)"

# Load patterns
declare -A LOAD_PATTERNS=(
    ["low"]="10"
    ["medium"]="50"
    ["high"]="100"
)

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
# Parse Arguments
##############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --duration)
                DURATION="$2"
                shift 2
                ;;
            --scenario)
                SCENARIO="$2"
                shift 2
                ;;
            --load-level)
                LOAD_LEVEL="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --duration SECONDS    Experiment duration (default: 300)"
                echo "  --scenario NAME       Scenario: baseline|contention|drcio|all"
                echo "  --load-level LEVEL    Load: low|medium|high (default: medium)"
                echo "  --help, -h            Show this help message"
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
# Prerequisites
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

    # Check if HP service is running
    if ! kubectl get deployment hp-gnn-service &> /dev/null; then
        log_error "HP service not deployed. Run ./deploy-all.sh first"
        exit 1
    fi

    # Check if HP service is ready
    local ready_replicas=$(kubectl get deployment hp-gnn-service -o jsonpath='{.status.readyReplicas}')
    if [ "$ready_replicas" -lt 1 ]; then
        log_error "HP service not ready. Wait for pods to become ready."
        exit 1
    fi

    # Get service endpoint
    HP_SERVICE_IP=$(kubectl get svc hp-gnn-service-internal -o jsonpath='{.spec.clusterIP}')

    if [ -z "$HP_SERVICE_IP" ]; then
        log_error "Cannot get HP service IP"
        exit 1
    fi

    log_success "Prerequisites met"
    log_info "HP Service IP: $HP_SERVICE_IP"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    log_info "Results will be saved to: $OUTPUT_DIR"
}

##############################################################################
# Load Generation
##############################################################################

generate_hp_load() {
    local duration=$1
    local rps=$2
    local output_file=$3

    log_info "Generating HP service load: $rps req/s for ${duration}s"

    # Run load generator pod
    kubectl run load-generator-hp \
        --image=williamyeh/hey:latest \
        --restart=Never \
        --rm \
        --attach \
        --quiet \
        -- \
        -z "${duration}s" \
        -q "$rps" \
        -m POST \
        -H "Content-Type: application/json" \
        -d '{"transaction_id":"exp_001","user_id":12345,"merchant_id":67890,"amount":150.00}' \
        "http://${HP_SERVICE_IP}:5000/predict" \
        > "$output_file" 2>&1 || true

    log_success "HP load generation complete"
}

start_lp_batch() {
    local num_jobs=$1

    log_info "Starting $num_jobs LP batch jobs..."

    for i in $(seq 1 "$num_jobs"); do
        kubectl create job "lp-batch-exp-$i" \
            --from=cronjob/lp-batch-stress-cron 2>/dev/null || \
        kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: lp-batch-exp-$i
  labels:
    app: lp-batch
    priority: low
    drcio.io/priority: low
    experiment: "true"
spec:
  completions: 1
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app: lp-batch
        priority: low
        drcio.io/priority: low
    spec:
      restartPolicy: Never
      containers:
        - name: io-stress
          image: $(kubectl get deployment hp-gnn-service -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/hp-service/lp-batch/')
          args:
            - "--work-dir=/data"
            - "--num-operations=5000"
            - "--io-pattern=sequential"
            - "--read-ratio=0.5"
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: work-dir
              mountPath: /data
      volumes:
        - name: work-dir
          emptyDir:
            sizeLimit: 2Gi
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
EOF
    done

    log_success "Started $num_jobs LP batch jobs"
}

stop_lp_batch() {
    log_info "Stopping LP batch jobs..."

    kubectl delete jobs -l experiment=true --wait=false || true

    log_success "LP batch jobs stopped"
}

##############################################################################
# Metrics Collection
##############################################################################

collect_metrics() {
    local scenario=$1
    local output_file=$2

    log_info "Collecting metrics for scenario: $scenario"

    # Query Prometheus for metrics
    local prometheus_url="http://localhost:9090"

    # Check if Prometheus is accessible
    if ! curl -s "$prometheus_url/api/v1/status/config" &> /dev/null; then
        log_warning "Prometheus not accessible at $prometheus_url"
        log_warning "Ensure port-forward is running: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
        return 1
    fi

    # Collect key metrics
    local end_time=$(date +%s)
    local start_time=$((end_time - DURATION))

    {
        echo "=== DRC-IO Experiment Metrics ==="
        echo "Scenario: $scenario"
        echo "Duration: ${DURATION}s"
        echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo ""

        # HP Service Latency (P50, P95, P99)
        echo "--- HP Service Latency ---"
        curl -s "${prometheus_url}/api/v1/query?query=histogram_quantile(0.50,rate(gnn_request_latency_seconds_bucket[1m]))" | \
            jq -r '.data.result[0].value[1] // "N/A"' | \
            awk '{printf "P50: %.2f ms\n", $1 * 1000}'

        curl -s "${prometheus_url}/api/v1/query?query=histogram_quantile(0.95,rate(gnn_request_latency_seconds_bucket[1m]))" | \
            jq -r '.data.result[0].value[1] // "N/A"' | \
            awk '{printf "P95: %.2f ms\n", $1 * 1000}'

        curl -s "${prometheus_url}/api/v1/query?query=histogram_quantile(0.99,rate(gnn_request_latency_seconds_bucket[1m]))" | \
            jq -r '.data.result[0].value[1] // "N/A"' | \
            awk '{printf "P99: %.2f ms\n", $1 * 1000}'

        echo ""

        # Request rate
        echo "--- Request Rate ---"
        curl -s "${prometheus_url}/api/v1/query?query=rate(gnn_requests_total[1m])" | \
            jq -r '.data.result[0].value[1] // "N/A"' | \
            awk '{printf "Requests/sec: %.2f\n", $1}'

        echo ""

        # I/O throughput
        echo "--- I/O Throughput ---"
        echo "High Priority:"
        curl -s "${prometheus_url}/api/v1/query?query=rate(drcio_io_bytes_read{priority=\"high\"}[1m])" | \
            jq -r '.data.result[0].value[1] // "0"' | \
            awk '{printf "  Read: %.2f MB/s\n", $1 / 1024 / 1024}'

        curl -s "${prometheus_url}/api/v1/query?query=rate(drcio_io_bytes_write{priority=\"high\"}[1m])" | \
            jq -r '.data.result[0].value[1] // "0"' | \
            awk '{printf "  Write: %.2f MB/s\n", $1 / 1024 / 1024}'

        echo "Low Priority:"
        curl -s "${prometheus_url}/api/v1/query?query=rate(drcio_io_bytes_read{priority=\"low\"}[1m])" | \
            jq -r '.data.result[0].value[1] // "0"' | \
            awk '{printf "  Read: %.2f MB/s\n", $1 / 1024 / 1024}'

        curl -s "${prometheus_url}/api/v1/query?query=rate(drcio_io_bytes_write{priority=\"low\"}[1m])" | \
            jq -r '.data.result[0].value[1] // "0"' | \
            awk '{printf "  Write: %.2f MB/s\n", $1 / 1024 / 1024}'

    } > "$output_file"

    log_success "Metrics collected: $output_file"
    cat "$output_file"
}

##############################################################################
# Experiment Scenarios
##############################################################################

run_baseline_scenario() {
    log_section "Scenario 1: Baseline (HP Service Only)"

    local rps=${LOAD_PATTERNS[$LOAD_LEVEL]}

    log_info "Configuration:"
    log_info "  Duration: ${DURATION}s"
    log_info "  Load: $rps req/s"
    log_info "  LP jobs: 0 (baseline)"

    # Generate load
    generate_hp_load "$DURATION" "$rps" "$OUTPUT_DIR/baseline-load.txt" &
    local load_pid=$!

    # Wait for completion
    wait $load_pid

    # Collect metrics
    sleep 10  # Wait for metrics to stabilize
    collect_metrics "baseline" "$OUTPUT_DIR/baseline-metrics.txt"

    log_success "Baseline scenario complete"
}

run_contention_scenario() {
    log_section "Scenario 2: Contention (HP + LP without DRC-IO)"

    local rps=${LOAD_PATTERNS[$LOAD_LEVEL]}

    # Temporarily disable DRC-IO (scale to 0)
    log_info "Disabling DRC-IO controller..."
    kubectl scale daemonset drcio-controller --replicas=0 || log_warning "Could not scale DRC-IO controller"

    sleep 10

    log_info "Configuration:"
    log_info "  Duration: ${DURATION}s"
    log_info "  Load: $rps req/s"
    log_info "  LP jobs: 2"
    log_info "  DRC-IO: disabled"

    # Start LP batch jobs
    start_lp_batch 2

    sleep 5

    # Generate HP load
    generate_hp_load "$DURATION" "$rps" "$OUTPUT_DIR/contention-load.txt" &
    local load_pid=$!

    # Wait for completion
    wait $load_pid

    # Stop LP jobs
    stop_lp_batch

    # Collect metrics
    sleep 10
    collect_metrics "contention" "$OUTPUT_DIR/contention-metrics.txt"

    # Re-enable DRC-IO
    log_info "Re-enabling DRC-IO controller..."
    kubectl scale daemonset drcio-controller --replicas=1 || log_warning "Could not scale DRC-IO controller"

    log_success "Contention scenario complete"
}

run_drcio_scenario() {
    log_section "Scenario 3: DRC-IO Enabled (HP + LP with prioritization)"

    local rps=${LOAD_PATTERNS[$LOAD_LEVEL]}

    # Ensure DRC-IO is running
    log_info "Ensuring DRC-IO controller is running..."
    kubectl scale daemonset drcio-controller --replicas=1 || true

    sleep 15  # Wait for controller to be ready

    log_info "Configuration:"
    log_info "  Duration: ${DURATION}s"
    log_info "  Load: $rps req/s"
    log_info "  LP jobs: 2"
    log_info "  DRC-IO: enabled"

    # Start LP batch jobs
    start_lp_batch 2

    sleep 5

    # Generate HP load
    generate_hp_load "$DURATION" "$rps" "$OUTPUT_DIR/drcio-load.txt" &
    local load_pid=$!

    # Wait for completion
    wait $load_pid

    # Stop LP jobs
    stop_lp_batch

    # Collect metrics
    sleep 10
    collect_metrics "drcio" "$OUTPUT_DIR/drcio-metrics.txt"

    log_success "DRC-IO scenario complete"
}

##############################################################################
# Results Analysis
##############################################################################

analyze_results() {
    log_section "Analyzing Results"

    if [ ! -d "$OUTPUT_DIR" ]; then
        log_error "No results found at $OUTPUT_DIR"
        return 1
    fi

    # Create summary
    local summary_file="$OUTPUT_DIR/summary.txt"

    {
        echo "=========================================="
        echo "DRC-IO Experiment Results Summary"
        echo "=========================================="
        echo ""
        echo "Experiment Date: $(date)"
        echo "Duration: ${DURATION}s"
        echo "Load Level: $LOAD_LEVEL"
        echo ""
        echo "=========================================="
        echo ""

        if [ -f "$OUTPUT_DIR/baseline-metrics.txt" ]; then
            echo "--- BASELINE (HP Only) ---"
            cat "$OUTPUT_DIR/baseline-metrics.txt"
            echo ""
        fi

        if [ -f "$OUTPUT_DIR/contention-metrics.txt" ]; then
            echo "--- CONTENTION (HP + LP, No DRC-IO) ---"
            cat "$OUTPUT_DIR/contention-metrics.txt"
            echo ""
        fi

        if [ -f "$OUTPUT_DIR/drcio-metrics.txt" ]; then
            echo "--- DRC-IO ENABLED (HP + LP with prioritization) ---"
            cat "$OUTPUT_DIR/drcio-metrics.txt"
            echo ""
        fi

        echo "=========================================="
        echo "Conclusion:"
        echo "Compare P95/P99 latencies across scenarios to see"
        echo "how DRC-IO maintains HP service performance even"
        echo "under LP batch workload contention."
        echo "=========================================="

    } > "$summary_file"

    cat "$summary_file"

    log_success "Results saved to: $OUTPUT_DIR"
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    log_section "✅ Experiment Complete"

    echo ""
    echo "📊 Results Location: $OUTPUT_DIR"
    echo ""
    echo "📈 View in Grafana:"
    echo "  http://localhost:3000"
    echo ""
    echo "📁 Output Files:"
    ls -lh "$OUTPUT_DIR"
    echo ""
    echo "💡 Analyze the P95 latency differences between scenarios"
    echo "   to see DRC-IO's impact on maintaining QoS."
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    parse_args "$@"

    log_section "🧪 DRC-IO Experiment Runner"

    log_info "Configuration:"
    log_info "  Scenario: $SCENARIO"
    log_info "  Duration: ${DURATION}s"
    log_info "  Load Level: $LOAD_LEVEL"

    check_prerequisites

    # Run scenarios
    case $SCENARIO in
        baseline)
            run_baseline_scenario
            ;;
        contention)
            run_contention_scenario
            ;;
        drcio)
            run_drcio_scenario
            ;;
        all)
            run_baseline_scenario
            sleep 30
            run_contention_scenario
            sleep 30
            run_drcio_scenario
            ;;
        *)
            log_error "Unknown scenario: $SCENARIO"
            exit 1
            ;;
    esac

    # Analyze results
    analyze_results

    # Print summary
    print_summary
}

# Run main function
main "$@"
