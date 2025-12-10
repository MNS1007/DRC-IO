# DRC-IO Experiment Scripts

Complete toolkit for running experiments, collecting data, and generating visualizations.

## Quick Start
```bash
# 1. Run all experiments (30 minutes)
./run-experiments.sh

# 2. Generate all plots
python3 plot-results.py --input experiment-results-YYYYMMDD-HHMMSS/

# 3. Create presentation slides
python3 create-presentation-slides.py --input experiment-results-YYYYMMDD-HHMMSS/

# Done! All results in experiment-results-YYYYMMDD-HHMMSS/
```

## Scripts Overview

### 1. `load-generator.py`
Sends HTTP load to HP service and records latency metrics.

**Usage:**
```bash
python3 load-generator.py \
  --url http://SERVICE-URL \
  --rps 10 \
  --duration 300 \
  --output results.csv
```

**Options:**
- `--url`: Service URL
- `--rps`: Requests per second (default: 10)
- `--duration`: Duration in seconds (default: 300)
- `--output`: Output CSV file

**Output:**
- CSV file with per-request latency data
- JSON summary with statistics

### 2. `run-experiments.sh`
Master script that orchestrates all three experimental scenarios.

**Usage:**
```bash
./run-experiments.sh
```

**What it does:**
1. Runs Scenario 1: Baseline (HP only)
2. Runs Scenario 2: No DRC-IO (contention)
3. Runs Scenario 3: With DRC-IO (solution)
4. Exports Prometheus metrics
5. Generates comparison report

**Duration:** ~30 minutes total

**Output directory:** `experiment-results-YYYYMMDD-HHMMSS/`

### 3. `export-prometheus.py`
Exports metrics from Prometheus for analysis.

**Usage:**
```bash
python3 export-prometheus.py \
  --duration 300 \
  --output metrics.json
```

**Metrics exported:**
- HP service latency (P50, P95, P99)
- Request rate
- SLA violation rate
- DRC-IO weights
- Resource usage

### 4. `analyze-results.py`
Analyzes experimental data and generates comparison report.

**Usage:**
```bash
python3 analyze-results.py --input experiment-results-YYYYMMDD-HHMMSS/
```

**Output:**
- `comparison.txt`: Formatted comparison table
- `summary.json`: Machine-readable results

### 5. `plot-results.py`
Generates all visualizations from experimental data.

**Usage:**
```bash
python3 plot-results.py --input experiment-results-YYYYMMDD-HHMMSS/
```

**Plots generated:**
- `plot_cdf.png`: Latency CDF comparison
- `plot_p95_latency.png`: P95 latency bar chart
- `plot_sla_violations.png`: SLA violation rates
- `plot_boxplot.png`: Latency distribution boxplot
- `plot_latency_timeseries.png`: Latency over time
- `plot_summary_table.png`: Results summary table
- `plot_drcio_weights.png`: DRC-IO weight adjustments

### 6. `create-presentation-slides.py`
Combines plots into presentation-ready slides.

**Usage:**
```bash
python3 create-presentation-slides.py --input experiment-results-YYYYMMDD-HHMMSS/
```

**Output:**
- `presentation_slide_results.png`: Main results slide
- `presentation_slide_comparison.png`: Comparison slide

## Dependencies
```bash
# Python packages
pip install pandas numpy matplotlib seaborn requests

# System tools
kubectl
curl
jq
```

## Manual Experiment Steps

If you want to run experiments manually:

### Scenario 1: Baseline
```bash
# Ensure LP is NOT running
kubectl delete job batch-stress -n fraud-detection

# Run load test
python3 load-generator.py \
  --url http://SERVICE-URL \
  --rps 10 \
  --duration 300 \
  --output scenario1.csv
```

### Scenario 2: No DRC-IO
```bash
# Disable DRC-IO
kubectl scale daemonset drcio-controller --replicas=0 -n fraud-detection

# Start LP
kubectl apply -f kubernetes/workloads/lp-job.yaml

# Wait 30 seconds for disk saturation

# Run load test
python3 load-generator.py \
  --url http://SERVICE-URL \
  --rps 10 \
  --duration 300 \
  --output scenario2.csv
```

### Scenario 3: With DRC-IO
```bash
# Enable DRC-IO
kubectl scale daemonset drcio-controller --replicas=1 -n fraud-detection

# LP still running from Scenario 2

# Wait 30 seconds for DRC-IO to adjust

# Run load test
python3 load-generator.py \
  --url http://SERVICE-URL \
  --rps 10 \
  --duration 300 \
  --output scenario3.csv
```

## Troubleshooting

### Service not responding
```bash
# Check service status
kubectl get svc gnn-service -n fraud-detection

# Check pod logs
kubectl logs -f deployment/gnn-service -n fraud-detection
```

### DRC-IO not adjusting
```bash
# Check DRC-IO logs
kubectl logs -f daemonset/drcio-controller -n fraud-detection

# Verify it's detecting HP pods
# Should see: "Discovered X HP pods, Y LP pods"
```

### Missing Prometheus metrics
```bash
# Check Prometheus is scraping
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open http://localhost:9090
# Run query: http_request_duration_seconds_bucket{namespace="fraud-detection"}
```

## Expected Results

**Scenario 1 (Baseline):**
- P95 latency: ~270ms
- SLA violations: <1%

**Scenario 2 (No DRC-IO):**
- P95 latency: ~880ms
- SLA violations: ~57%

**Scenario 3 (With DRC-IO):**
- P95 latency: ~450ms
- SLA violations: ~2%

**Key metric:** 2.0x latency improvement, 27x reduction in SLA violations
