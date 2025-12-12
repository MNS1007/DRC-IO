#!/bin/bash
##############################################################################
# Export Metrics from Prometheus
#
# This script exports metrics from Prometheus for offline analysis.
# Metrics are exported in CSV format for easy analysis in spreadsheets
# or data science tools.
#
# Usage:
#   ./export-metrics.sh [OPTIONS]
#
# Options:
#   --duration MINUTES    Duration to export (default: 60)
#   --output FILE         Output file (default: metrics-export.csv)
#   --metrics NAMES       Comma-separated metric names (default: all)
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

# Configuration
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
DURATION=60  # minutes
OUTPUT_FILE="metrics-export-$(date +%Y%m%d-%H%M%S).csv"
METRICS="all"

# Metric queries
declare -A METRIC_QUERIES=(
    ["gnn_latency_p50"]="histogram_quantile(0.50, rate(gnn_request_latency_seconds_bucket[1m]))"
    ["gnn_latency_p95"]="histogram_quantile(0.95, rate(gnn_request_latency_seconds_bucket[1m]))"
    ["gnn_latency_p99"]="histogram_quantile(0.99, rate(gnn_request_latency_seconds_bucket[1m]))"
    ["gnn_request_rate"]="rate(gnn_requests_total[1m])"
    ["hp_io_read_rate"]="rate(drcio_io_bytes_read{priority=\"high\"}[1m])"
    ["hp_io_write_rate"]="rate(drcio_io_bytes_write{priority=\"high\"}[1m])"
    ["lp_io_read_rate"]="rate(drcio_io_bytes_read{priority=\"low\"}[1m])"
    ["lp_io_write_rate"]="rate(drcio_io_bytes_write{priority=\"low\"}[1m])"
    ["hp_io_weight"]="avg(drcio_io_weight{priority=\"high\"})"
    ["lp_io_weight"]="avg(drcio_io_weight{priority=\"low\"})"
    ["batch_io_ops"]="rate(batch_io_operations_total[1m])"
    ["controller_loop_duration"]="rate(drcio_control_loop_duration_seconds_sum[1m])"
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
            --duration)
                DURATION="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --metrics)
                METRICS="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --duration MINUTES    Duration to export (default: 60)"
                echo "  --output FILE         Output file"
                echo "  --metrics NAMES       Comma-separated metric names"
                echo "  --help, -h            Show this help message"
                echo ""
                echo "Available metrics:"
                for metric in "${!METRIC_QUERIES[@]}"; do
                    echo "  - $metric"
                done
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
# Prometheus Queries
##############################################################################

check_prometheus() {
    log_section "Checking Prometheus Connection"

    if ! curl -s "${PROMETHEUS_URL}/api/v1/status/config" &> /dev/null; then
        log_error "Cannot connect to Prometheus at $PROMETHEUS_URL"
        log_info "Ensure Prometheus is accessible:"
        log_info "  kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
        exit 1
    fi

    log_success "Connected to Prometheus"
}

query_prometheus() {
    local query=$1
    local start_time=$2
    local end_time=$3

    # Query range data
    local url="${PROMETHEUS_URL}/api/v1/query_range"
    url+="?query=$(echo "$query" | jq -sRr @uri)"
    url+="&start=${start_time}"
    url+="&end=${end_time}"
    url+="&step=60s"  # 1-minute resolution

    curl -s "$url" | jq -r '
        .data.result[] |
        .values[] |
        @csv
    ' 2>/dev/null || echo ""
}

##############################################################################
# Export Metrics
##############################################################################

export_metrics() {
    log_section "Exporting Metrics"

    # Calculate time range
    local end_time=$(date +%s)
    local start_time=$((end_time - DURATION * 60))

    log_info "Time range: $(date -d @$start_time '+%Y-%m-%d %H:%M:%S') to $(date -d @$end_time '+%Y-%m-%d %H:%M:%S')"

    # Create CSV header
    {
        echo -n "timestamp"
        for metric in "${!METRIC_QUERIES[@]}"; do
            if [ "$METRICS" = "all" ] || echo "$METRICS" | grep -q "$metric"; then
                echo -n ",$metric"
            fi
        done
        echo ""
    } > "$OUTPUT_FILE"

    # Export each metric
    local temp_dir=$(mktemp -d)

    for metric in "${!METRIC_QUERIES[@]}"; do
        if [ "$METRICS" != "all" ] && ! echo "$METRICS" | grep -q "$metric"; then
            continue
        fi

        log_info "Querying: $metric"

        query_prometheus "${METRIC_QUERIES[$metric]}" "$start_time" "$end_time" \
            > "$temp_dir/${metric}.csv"
    done

    # Merge all metrics by timestamp
    log_info "Merging metrics..."

    # This is a simplified merge - in production, use a proper time-series join
    # For now, just append columns
    for metric in "${!METRIC_QUERIES[@]}"; do
        if [ "$METRICS" != "all" ] && ! echo "$METRICS" | grep -q "$metric"; then
            continue
        fi

        if [ -f "$temp_dir/${metric}.csv" ] && [ -s "$temp_dir/${metric}.csv" ]; then
            # Append metric values to CSV
            paste -d',' "$OUTPUT_FILE" "$temp_dir/${metric}.csv" > "$OUTPUT_FILE.tmp" || true
            mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE" || true
        fi
    done

    # Cleanup
    rm -rf "$temp_dir"

    log_success "Metrics exported to: $OUTPUT_FILE"

    # Show file info
    if [ -f "$OUTPUT_FILE" ]; then
        local line_count=$(wc -l < "$OUTPUT_FILE")
        local file_size=$(du -h "$OUTPUT_FILE" | cut -f1)

        log_info "File size: $file_size"
        log_info "Data points: $((line_count - 1))"
    fi
}

##############################################################################
# Generate Summary Statistics
##############################################################################

generate_summary() {
    log_section "Generating Summary Statistics"

    if [ ! -f "$OUTPUT_FILE" ]; then
        log_error "Output file not found: $OUTPUT_FILE"
        return 1
    fi

    local summary_file="${OUTPUT_FILE%.csv}-summary.txt"

    {
        echo "=========================================="
        echo "DRC-IO Metrics Export Summary"
        echo "=========================================="
        echo ""
        echo "Export Date: $(date)"
        echo "Duration: ${DURATION} minutes"
        echo "Prometheus URL: $PROMETHEUS_URL"
        echo ""
        echo "Output File: $OUTPUT_FILE"
        echo "File Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
        echo "Data Points: $(($(wc -l < "$OUTPUT_FILE") - 1))"
        echo ""
        echo "Exported Metrics:"
        for metric in "${!METRIC_QUERIES[@]}"; do
            if [ "$METRICS" = "all" ] || echo "$METRICS" | grep -q "$metric"; then
                echo "  - $metric"
            fi
        done
        echo ""
        echo "=========================================="
        echo "Analysis Tips:"
        echo "  1. Import CSV into Excel, Google Sheets, or pandas"
        echo "  2. Create time-series plots for latency trends"
        echo "  3. Compare HP vs LP I/O throughput"
        echo "  4. Correlate DRC-IO weight changes with performance"
        echo "=========================================="

    } > "$summary_file"

    cat "$summary_file"

    log_success "Summary saved to: $summary_file"
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    log_section "✅ Export Complete"

    echo ""
    echo "📁 Files Generated:"
    echo "  - $OUTPUT_FILE"
    echo "  - ${OUTPUT_FILE%.csv}-summary.txt"
    echo ""
    echo "📊 Next Steps:"
    echo "  1. Open CSV in your preferred analysis tool"
    echo "  2. Create visualizations of key metrics"
    echo "  3. Compare baseline vs DRC-IO scenarios"
    echo ""
    echo "💡 Example Analysis (Python):"
    echo "  import pandas as pd"
    echo "  df = pd.read_csv('$OUTPUT_FILE')"
    echo "  df.plot(x='timestamp', y='gnn_latency_p95')"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    parse_args "$@"

    log_section "📤 Exporting Metrics from Prometheus"

    log_info "Configuration:"
    log_info "  Duration: ${DURATION} minutes"
    log_info "  Output: $OUTPUT_FILE"
    log_info "  Metrics: $METRICS"

    check_prometheus
    export_metrics
    generate_summary
    print_summary
}

# Run main function
main "$@"
