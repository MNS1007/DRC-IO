# DRC-IO on EKS

![DRC-IO Architecture](assets/architecture-diagram.png)


Setup Guide
For users cloning this repo who need to provision everything themselves.

### Requirements
- `kubectl`, `helm`, `aws` CLI, and `docker` installed locally.
- AWS account with permissions to create EKS clusters, IAM roles, EBS volumes.

### Step 1: Provision Infrastructure
```bash
cd infrastructure
./setup.sh                # creates EKS, installs metrics-server & monitoring, sets up port-forwards
```
If monitoring pods stay Pending, run `./fix-ebs-csi.sh` (repairs the EBS CSI addon) and rerun the Helm command printed in the summary. Tear down with `./cleanup.sh` when finished.

### Step 2: Build & Deploy Workloads
```bash
cd ..
./scripts/build-push.sh   # build/push docker images (HP service, LP batch, DRC-IO controller)
./scripts/deploy-all.sh   # deploy workloads + controller into fraud-detection namespace
```

### Step 3: Run Experiments
```bash
./scripts/run-scenario1.sh   # Baseline
./scripts/run-scenario2.sh   # No DRC-IO
./scripts/run-scenario3.sh   # With DRC-IO
```
After validating each scenario, you can optionally run `./scripts/run-experiments.sh` to automate the trio. Outputs (CSV + JSON metrics + logs + plots) land in `experiment-results-*`. The included Docker image (`public.ecr.aws/our-repo/drcio-eval:latest`) can run all scripts if you prefer containerized tooling.

### Step 4: Monitoring & Metrics
```bash
./scripts/port-forward-monitoring.sh   # Grafana http://127.0.0.1:3000, Prometheus http://127.0.0.1:9090
python3 scripts/export-prometheus.py --use-kubectl-port-forward --duration 300 --output metrics.json
```
Grafana dashboards live in `dashboards/`. CloudWatch agent manifests are under `kubernetes/monitoring/cloudwatch-agent.yaml` if you want AWS-side observability.

To recreate the io.weight chart from Scenario 3, follow the same Grafana steps as above or run `scripts/export-prometheus.py` to capture `drcio_hp_weight`/`drcio_lp_weight` metrics for plotting.

### Step 5: Cleanup
```bash
cd infrastructure
./cleanup.sh
```
`cleanup.sh` tears down the EKS cluster, node groups, IAM roles, and monitoring stack. Run it whenever you finish testing so we don’t leave AWS resources running indefinitely; re-run `setup.sh` to recreate everything for the next test cycle.

### Need Help?
Open an issue or email nithin10@umd.edu with logs (attach `scripts/.pf-logs/*` and relevant `kubectl describe` output). Common issues: missing EBS CSI IAM policy, stale kubeconfig context, or Grafana PVC not re-created.
