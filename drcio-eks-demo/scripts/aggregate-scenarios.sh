#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FINAL_DIR=${1:-"$REPO_ROOT/experiment-results-real"}

SC1_DIR="$REPO_ROOT/experiment-scenario1-20251210-172942"
SC2_DIR="$REPO_ROOT/experiment-scenario2-20251210-170235"
SC3_DIR="$REPO_ROOT/experiment-scenario3-20251210-173932"

mkdir -p "$FINAL_DIR"

cp "$SC1_DIR/scenario1-baseline.csv" "$FINAL_DIR/" || true
cp "$SC1_DIR/scenario1-baseline_summary.json" "$FINAL_DIR/scenario1-baseline_summary.json" || true
cp "$SC2_DIR/scenario2-no-drcio.csv" "$FINAL_DIR/" || true
cp "$SC2_DIR/scenario2-metrics.json" "$FINAL_DIR/scenario2-metrics.json" || true
cp "$SC3_DIR/scenario3-with-drcio.csv" "$FINAL_DIR/" || true
cp "$SC3_DIR/scenario3-metrics.json" "$FINAL_DIR/scenario3-metrics.json" || true

python3 "$SCRIPT_DIR/analyze-results.py" --input "$FINAL_DIR"
python3 "$SCRIPT_DIR/plot-results.py" --input "$FINAL_DIR"
