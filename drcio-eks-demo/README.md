# DRC-IO on EKS — Submission Guide

Minimal instructions to deploy the demo workloads, run the three DRC-IO scenarios, and package the required artifacts for submission.

## Requirements
- `kubectl` connected to the target EKS cluster (cluster should already have the `fraud-detection` namespace and worker IAM permissions to create jobs/daemonsets).
- `python3` with the standard library only (project code bundles everything else).
- `helm` and `aws` CLI (only needed if you must provision the cluster or reinstall monitoring).

## 1. Deploy/Refresh the Demo Stack
```bash
# Build/push images if you changed code (optional)
./scripts/build-push.sh

# Deploy HP service, LP job manifest, and the DRC-IO controller
./scripts/deploy-all.sh
```

Provisioning from scratch? `./infrastructure/setup.sh` bootstraps the EKS cluster plus kube-prometheus-stack; run it once before the steps above.

## 2. Run the Scenarios
```bash
# Run all three scenarios with prompts and summaries
./scripts/run-experiments.sh

# or run them individually if you need to re-collect a specific dataset
./scripts/run-scenario1.sh
./scripts/run-scenario2.sh
./scripts/run-scenario3.sh
```
Outputs land in timestamped `experiment-results-*` folders (CSV request traces, Prometheus metrics, controller logs, and analysis reports).

## 3. Export Metrics & Visualize (optional but recommended)
```bash
# Open Prometheus + Grafana locally
./scripts/port-forward-monitoring.sh

# Export metrics for any run (handles kubectl port-forward if needed)
python3 ./scripts/export-prometheus.py \
  --use-kubectl-port-forward \
  --duration 300 \
  --output experiment-results-YYYYMMDD-HHMMSS/scenario1-metrics.json
```
Grafana dashboards live under `dashboards/` and the CloudWatch agent manifest is at `kubernetes/monitoring/cloudwatch-agent.yaml` if you need AWS-side telemetry.

## 4. Submission Checklist
1. Commit/push this repository to your public link **including one full `experiment-results-*` directory** that reproduces the demo graphs.
2. Verify the code runs end-to-end without extra package installs (Python standard library only) and that `kubectl`/`helm`/`aws` CLIs are available in your environment.
3. Include your IAM user or role comment when you submit, e.g.
   ```
   # IAM User: fraud-eval (arn:aws:iam::123456789012:user/fraud-eval)
   ```
   Reviewer will use it to reach CloudWatch logs for validation.

That’s it—everything else in the repo is self-contained. Reach out if you need tailored instructions for a different cluster layout or IAM model.
