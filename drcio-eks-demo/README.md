# DRC-IO on AWS EKS - Complete Demo Project

**Dynamic Resource Control for I/O (DRC-IO)** - A demonstration of intelligent I/O prioritization in Kubernetes clusters running on AWS EKS.

## Overview

This project demonstrates DRC-IO's ability to maintain Quality of Service (QoS) for high-priority workloads even when low-priority batch jobs are consuming I/O resources. It uses real-world scenarios with:

- **High-Priority Workload**: Real-time GNN (Graph Neural Network) fraud detection service
- **Low-Priority Workload**: Batch I/O-intensive data processing jobs
- **DRC-IO Controller**: Dynamic I/O weight management using cgroup v2

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS EKS Cluster                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────┐         ┌─────────────────────────┐  │
│  │  HP GNN Service  │         │  DRC-IO Controller      │  │
│  │  (Priority: High)│◄────────┤  (DaemonSet)            │  │
│  │  I/O Weight: 1000│         │  - Monitors workloads   │  │
│  └──────────────────┘         │  - Sets I/O weights     │  │
│                                │  - Collects metrics     │  │
│  ┌──────────────────┐         └─────────────────────────┘  │
│  │  LP Batch Jobs   │                      │                │
│  │  (Priority: Low) │◄─────────────────────┘                │
│  │  I/O Weight: 10  │                                       │
│  └──────────────────┘                                       │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Monitoring Stack (Prometheus + Grafana)           │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
drcio-eks-demo/
├── infrastructure/           # EKS cluster setup
│   ├── eks-cluster.yaml     # eksctl configuration
│   ├── setup.sh             # Automated setup script
│   └── cleanup.sh           # Teardown script
│
├── docker/                   # Container images
│   ├── hp-service/          # High-priority GNN service
│   │   ├── app.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── lp-batch/            # Low-priority batch workload
│   │   ├── stress.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   └── drcio/               # DRC-IO controller
│       ├── controller.py
│       ├── Dockerfile
│       └── requirements.txt
│
├── kubernetes/               # Kubernetes manifests
│   ├── monitoring/          # Prometheus & Grafana configs
│   ├── workloads/           # Application deployments
│   └── drcio/               # DRC-IO controller deployment
│
├── dashboards/              # Grafana dashboards
│   └── drcio-dashboard.json
│
├── scripts/                 # Automation scripts
│   ├── build-push.sh        # Build and push images
│   ├── deploy-all.sh        # Deploy all components
│   ├── run-experiment.sh    # Run experiments
│   └── export-metrics.sh    # Export metrics
│
└── README.md                # This file
```

## Prerequisites

### Required Tools

1. **AWS CLI** (v2.x or higher)
   ```bash
   aws --version
   ```

2. **eksctl** (0.150.0 or higher)
   ```bash
   eksctl version
   ```

3. **kubectl** (v1.28 or higher)
   ```bash
   kubectl version --client
   ```

4. **Helm** (v3.x)
   ```bash
   helm version
   ```

5. **Docker** (for building images)
   ```bash
   docker --version
   ```

### AWS Setup

1. **Configure AWS credentials:**
   ```bash
   aws configure
   ```

2. **Verify AWS access:**
   ```bash
   aws sts get-caller-identity
   ```

3. **Set environment variables (optional):**
   ```bash
   export AWS_REGION=us-east-1
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   ```

## Quick Start

### Step 1: Set Up Infrastructure

Deploy the EKS cluster and monitoring stack:

```bash
cd infrastructure
./setup.sh
```

This script will:
- Create an EKS cluster (15-20 minutes)
- Install metrics-server
- Deploy Prometheus and Grafana
- Configure port forwarding

**Expected output:**
```
✅ AWS EKS Infrastructure Ready!
════════════════════════════════════════════
Cluster: drcio-demo
Region: us-east-1
Grafana: http://localhost:3000
  Username: admin
  Password: <saved in grafana-password.txt>
Prometheus: http://localhost:9090
════════════════════════════════════════════
```

### Step 2: Build and Push Docker Images

Build all container images and push to Amazon ECR:

```bash
cd ../scripts
./build-push.sh
```

This will:
- Create ECR repositories
- Build all Docker images
- Push to ECR
- Update Kubernetes manifests with image URLs

### Step 3: Deploy Workloads

Deploy DRC-IO controller and workloads:

```bash
./deploy-all.sh
```

This deploys:
- DRC-IO controller (DaemonSet)
- High-priority GNN service
- Low-priority batch jobs
- Storage configuration

**Verify deployment:**
```bash
kubectl get pods -A
kubectl get svc
```

### Step 4: Run Experiments

Execute experiments to see DRC-IO in action:

```bash
./run-experiment.sh --scenario all --load-level medium
```

This runs three scenarios:
1. **Baseline**: HP service only (no contention)
2. **Contention**: HP + LP without DRC-IO (degraded performance)
3. **DRC-IO**: HP + LP with I/O prioritization (maintained performance)

## Detailed Usage

### Infrastructure Management

#### Create Infrastructure
```bash
cd infrastructure
./setup.sh
```

#### Destroy Infrastructure
```bash
cd infrastructure
./cleanup.sh
```

**Note**: The cleanup script shows cost estimates before deletion.

### Docker Image Management

#### Build All Images
```bash
cd scripts
./build-push.sh
```

#### Build Specific Service
```bash
./build-push.sh --service hp-service
```

#### Skip Push (build only)
```bash
./build-push.sh --skip-push
```

### Kubernetes Deployment

#### Deploy Everything
```bash
cd scripts
./deploy-all.sh
```

#### Deploy Without Controller
```bash
./deploy-all.sh --skip-controller
```

#### Dry Run
```bash
./deploy-all.sh --dry-run
```

#### Manual Deployment
```bash
# Deploy namespace
kubectl apply -f kubernetes/workloads/namespace.yaml

# Deploy storage
kubectl apply -f kubernetes/workloads/storage.yaml

# Deploy DRC-IO controller
kubectl apply -f kubernetes/drcio/serviceaccount.yaml
kubectl apply -f kubernetes/drcio/rbac.yaml
kubectl apply -f kubernetes/drcio/daemonset.yaml

# Deploy workloads
kubectl apply -f kubernetes/workloads/hp-deployment.yaml
kubectl apply -f kubernetes/workloads/hp-service.yaml
kubectl apply -f kubernetes/workloads/lp-job.yaml
```

### Running Experiments

#### Run All Scenarios (Recommended)
```bash
cd scripts
./run-experiment.sh --scenario all --duration 300
```

#### Run Specific Scenario
```bash
# Baseline only
./run-experiment.sh --scenario baseline

# Contention test
./run-experiment.sh --scenario contention

# DRC-IO test
./run-experiment.sh --scenario drcio
```

#### Adjust Load Level
```bash
# Low load
./run-experiment.sh --load-level low

# High load
./run-experiment.sh --load-level high
```

### Monitoring and Metrics

#### Access Grafana
1. Ensure port-forward is running:
   ```bash
   kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
   ```

2. Open browser: http://localhost:3000

3. Login:
   - Username: `admin`
   - Password: (see `infrastructure/grafana-password.txt`)

4. Navigate to: **Dashboards → DRC-IO → DRC-IO Overview Dashboard**

#### Access Prometheus
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Open: http://localhost:9090

#### Export Metrics
```bash
cd scripts
./export-metrics.sh --duration 60 --output my-metrics.csv
```

#### View Logs

```bash
# DRC-IO controller logs
kubectl logs -f -l app=drcio-controller

# HP service logs
kubectl logs -f -l app=hp-gnn-service

# Batch job logs
kubectl logs -f -l app=lp-batch
```

## Key Metrics

### High-Priority Service Metrics

- **gnn_request_latency_seconds**: Request latency histogram
  - P50, P95, P99 percentiles
- **gnn_requests_total**: Total request count
- **gnn_active_requests**: Current active requests
- **gnn_risk_score**: Distribution of risk scores

### DRC-IO Controller Metrics

- **drcio_io_weight**: Current I/O weight per pod
- **drcio_io_bytes_read**: Bytes read from disk
- **drcio_io_bytes_write**: Bytes written to disk
- **drcio_workload_discovery_total**: Workload discoveries
- **drcio_io_weight_applied_total**: I/O weight applications
- **drcio_active_pods**: Active pods under management

### Batch Workload Metrics

- **batch_io_operations_total**: Total I/O operations
- **batch_io_bytes_total**: Total bytes processed
- **batch_io_latency_seconds**: I/O operation latency
- **batch_active_operations**: Active I/O operations

## Understanding the Results

### Expected Outcomes

1. **Baseline Scenario**
   - P95 latency: ~50-100ms
   - Stable performance
   - No I/O contention

2. **Contention Scenario (No DRC-IO)**
   - P95 latency: ~200-500ms (2-5x degradation)
   - High variability
   - Batch jobs impact service performance

3. **DRC-IO Scenario**
   - P95 latency: ~60-120ms (maintained)
   - Minimal degradation
   - Batch jobs throttled automatically

### Visualization

Access Grafana to see:
- Real-time latency trends
- I/O weight adjustments
- Throughput comparison (HP vs LP)
- Resource utilization

## Troubleshooting

### Infrastructure Issues

#### EKS Cluster Creation Fails
```bash
# Check AWS limits
aws service-quotas list-service-quotas \
  --service-code eks \
  --region us-east-1

# View CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name eksctl-drcio-demo-cluster
```

#### Cannot Connect to Cluster
```bash
# Update kubeconfig
aws eks update-kubeconfig \
  --name drcio-demo \
  --region us-east-1

# Verify connection
kubectl cluster-info
kubectl get nodes
```

### Deployment Issues

#### Pods Not Starting
```bash
# Check pod status
kubectl get pods -A

# View pod events
kubectl describe pod <pod-name>

# Check logs
kubectl logs <pod-name>
```

#### Image Pull Errors
```bash
# Verify ECR authentication
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# Check if images exist
aws ecr list-images \
  --repository-name drcio/hp-service \
  --region us-east-1
```

#### DRC-IO Controller Not Working
```bash
# Check controller logs
kubectl logs -l app=drcio-controller

# Verify permissions
kubectl auth can-i list pods --as=system:serviceaccount:default:drcio-controller

# Check cgroup v2 support
kubectl exec -it <drcio-pod> -- ls -la /sys/fs/cgroup
```

### Monitoring Issues

#### Grafana Not Accessible
```bash
# Check Grafana pod
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# Restart port-forward
pkill -f "port-forward"
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

#### Missing Metrics
```bash
# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open: http://localhost:9090/targets

# Verify ServiceMonitors
kubectl get servicemonitors -A

# Check pod annotations
kubectl get pods -o yaml | grep prometheus.io
```

## Cost Optimization

### Estimated Monthly Costs

| Resource | Type | Cost |
|----------|------|------|
| EKS Control Plane | - | ~$73/month |
| EC2 Worker Nodes | 1× t3.xlarge | ~$121/month |
| EBS Volumes | 50GB gp3 | ~$4/month |
| NAT Gateway | Single AZ | ~$33/month |
| Data Transfer | Varies | ~$10-50/month |
| **Total** | | **~$240-280/month** |

### Reduce Costs

1. **Stop cluster when not in use:**
   ```bash
   cd infrastructure
   ./cleanup.sh
   ```

2. **Use Spot Instances** (edit `eks-cluster.yaml`):
   ```yaml
   managedNodeGroups:
     - name: spot-workers
       instanceTypes: ["t3.xlarge", "t3a.xlarge"]
       spot: true
   ```

3. **Scale down monitoring:**
   ```bash
   kubectl scale deployment -n monitoring prometheus-grafana --replicas=0
   kubectl scale statefulset -n monitoring prometheus-kube-prometheus-prometheus --replicas=0
   ```

4. **Use smaller instance types** (for testing only):
   ```yaml
   instanceType: t3.medium  # 2 vCPU, 4GB RAM
   ```

## Advanced Configuration

### Customize I/O Weights

Edit `docker/drcio/controller.py`:

```python
IO_WEIGHTS = {
    'high': 1000,    # High priority
    'medium': 100,   # Medium priority
    'low': 10        # Low priority
}
```

### Add Priority Classes

Create custom priority labels:

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    drcio.io/priority: critical  # Custom priority
```

Update controller to handle new priorities.

### Integrate with Existing Workloads

Add labels to your deployments:

```yaml
metadata:
  labels:
    drcio.io/priority: high  # or 'medium', 'low'
```

### Multi-Node Deployment

Increase node count in `eks-cluster.yaml`:

```yaml
managedNodeGroups:
  - name: standard-workers
    desiredCapacity: 3  # Multiple nodes
    minSize: 2
    maxSize: 5
```

## Performance Tuning

### High-Priority Service

Adjust resources in `kubernetes/workloads/hp-deployment.yaml`:

```yaml
resources:
  requests:
    cpu: 1000m      # Increase CPU
    memory: 1Gi     # Increase memory
```

### Batch Workload

Tune I/O operations in `kubernetes/workloads/lp-job.yaml`:

```yaml
args:
  - "--num-operations=5000"  # More operations
  - "--num-workers=8"        # More parallelism
```

### DRC-IO Controller

Adjust control loop interval in `docker/drcio/controller.py`:

```python
sleep_time = 5  # Control loop interval (seconds)
```

## Research and Citations

This project implements concepts from:

- **DRC-IO Paper**: Dynamic Resource Control for I/O in Kubernetes
- **cgroup v2 Documentation**: Linux kernel resource management
- **Kubernetes QoS Classes**: Pod priority and preemption

## Contributing

This is a demonstration project. For production use:

1. Add comprehensive error handling
2. Implement proper authentication
3. Add backup and recovery procedures
4. Configure high availability
5. Implement security best practices

## License

This project is provided as-is for educational and research purposes.

## Support

For issues and questions:
- Check the troubleshooting section
- Review logs: `kubectl logs`
- Examine events: `kubectl get events`
- Verify configuration: `kubectl get pods -o yaml`

## Cleanup

When you're done, clean up all resources:

```bash
cd infrastructure
./cleanup.sh
```

This will:
- Delete the EKS cluster
- Remove all workloads
- Delete load balancers
- Clean up VPC resources
- Show cost summary

**Warning**: This action is irreversible. All data will be lost.

## Next Steps

After completing the demo:

1. **Analyze Results**: Compare latency metrics across scenarios
2. **Customize Workloads**: Add your own applications
3. **Scale Up**: Test with multiple nodes
4. **Integrate**: Connect to your existing monitoring
5. **Optimize**: Tune I/O weights for your workloads

## Acknowledgments

Built for demonstrating DRC-IO research and development.

---

**Happy experimenting with DRC-IO! 🚀**

For questions or feedback, please open an issue in the repository.
