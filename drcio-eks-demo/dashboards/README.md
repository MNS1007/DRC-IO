# DRC-IO Grafana Dashboard Setup

Complete monitoring dashboard for DRC-IO experiments.

## Quick Setup
```bash
# 1. Ensure port-forwarding is active
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 &

# 2. Import dashboard
cd scripts
./import-dashboard.sh

# 3. Open Grafana
open http://localhost:3000
# Login: admin / (password from infrastructure/grafana-password.txt)

# Dashboard will be set as home page automatically
```

## Dashboard Panels

### Row 1: Latency Monitoring
**Panel 1.1: GNN Service Latency (P50/P95/P99)**
- Shows latency percentiles over time
- Red threshold line at 500ms (SLA)
- Legend shows mean, current, and max values

**Panel 1.2: Current P95 Latency (Gauge)**
- Real-time P95 latency
- Color-coded: Green (<400ms), Yellow (400-500ms), Red (>500ms)

**Panel 1.3: SLA Violation Rate (Gauge)**
- Percentage of requests exceeding 500ms
- Based on last 5 minutes
- Color thresholds: Green (<2%), Yellow (2-5%), Red (>10%)

### Row 2: Request Metrics
**Panel 2.1: Request Rate**
- Requests per second over time
- Shows traffic patterns

**Panel 2.2: SLA Violations Over Time**
- Percentage of SLA violations
- Helps identify when contention occurs

### Row 3: DRC-IO Controller
**Panel 3.1: DRC-IO I/O Weights**
- **MOST IMPORTANT PANEL FOR DEMO!**
- Shows HP weight (blue) and LP weight (orange)
- Step function shows when DRC-IO adjusts priorities
- Look for: 
  * Baseline: Both at 500 (equal)
  * Contention detected: HP jumps to 800, LP drops to 200
  * Relaxation: Gradual return to balanced state

**Panel 3.2: DRC-IO Adjustments Counter**
- Total adjustments in last 5 minutes
- Shows how often DRC-IO is acting

### Row 4: Resource Usage
**Panel 4.1: HP Service CPU Usage**
- CPU percentage per pod
- Helps verify pods are healthy

**Panel 4.2: HP Service Memory Usage**
- Memory consumption per pod
- Monitor for memory leaks

## Using During Experiments

### Scenario 1: Baseline
**Expected:**
- Latency: ~250ms P95
- SLA violations: <1%
- DRC-IO weights: Both 500 (no adjustments needed)

### Scenario 2: No DRC-IO (disable controller)
```bash
kubectl scale daemonset drcio-controller --replicas=0 -n fraud-detection
kubectl apply -f kubernetes/workloads/lp-job.yaml
```

**Expected:**
- Latency: Spikes to ~900ms P95
- SLA violations: ~60%
- DRC-IO weights: Flat at 500 (controller disabled)

### Scenario 3: With DRC-IO (enable controller)
```bash
kubectl scale daemonset drcio-controller --replicas=1 -n fraud-detection
# LP job still running from Scenario 2
```

**Expected:**
- Latency: Drops to ~450ms P95 within 30 seconds
- SLA violations: Drops to ~2%
- DRC-IO weights: **You'll see HP jump to 800, LP drop to 200!**

## Demo Tips

### For Live Presentations

1. **Open dashboard in fullscreen** (press 'F' or use fullscreen button)

2. **Set time range to "Last 5 minutes"** for real-time view

3. **Point out the I/O Weights panel when DRC-IO activates:**
   - Describe how weights jump in response to contention
   - Highlight that HP weight increases while LP decreases
4. **Show correlation between weights and latency:** watch latency drop as HP weight increases
5. **Use auto-refresh** - Set to 5 seconds for smooth updates

### For Screenshots

1. **Capture during Scenario 3** when DRC-IO is actively adjusting

2. **Include I/O Weights panel** - this is your proof DRC-IO works!

3. **Use annotations** to mark when you:
   - Started LP batch job
   - Enabled DRC-IO
   - Disabled DRC-IO

## Troubleshooting

### Dashboard shows "No data"
```bash
# Check Prometheus is scraping
kubectl get servicemonitor -n monitoring

# Check HP service is exposing metrics
kubectl port-forward -n fraud-detection svc/gnn-service 8000:80
curl http://localhost:8000/metrics

# Should see: http_request_duration_seconds_bucket{...}
```

### DRC-IO weights not showing
```bash
# Check DRC-IO pod is running
kubectl get pods -n fraud-detection -l app=drcio-controller

# Check DRC-IO logs
kubectl logs -f daemonset/drcio-controller -n fraud-detection

# Check DRC-IO metrics endpoint
kubectl port-forward -n fraud-detection svc/drcio-controller 8080:8080
curl http://localhost:8080/metrics

# Should see: drcio_hp_weight, drcio_lp_weight
```

### Prometheus datasource not working
```bash
# Check Prometheus is accessible from Grafana
kubectl exec -it -n monitoring prometheus-grafana-xxx -- sh
wget -O- http://prometheus-kube-prometheus-prometheus.monitoring:9090/api/v1/query?query=up

# Should return JSON with metrics
```

## Manual Dashboard Import

If automated script fails:

1. Open Grafana: http://localhost:3000
2. Login: admin / (password from file)
3. Click "+" → "Import"
4. Upload `dashboards/drcio-dashboard.json`
5. Select "Prometheus" as datasource
6. Click "Import"

## Exporting Dashboard

To save modified dashboard:

1. Open dashboard
2. Click "Share" (top right)
3. Click "Export"
4. Click "Save to file"
5. Replace `dashboards/drcio-dashboard.json`
