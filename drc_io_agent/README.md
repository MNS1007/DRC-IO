# DRC I/O Agent

Dynamic Resource Controller for Input and Output Scheduling (Node Agent), fix.

## Overview

This Kubernetes DaemonSet agent runs on each worker node to:
1. Detect application containers with `group-id=hp` (high priority) and `group-id=lp` (low priority) labels
2. Identify Linux cgroup paths for these containers
3. Apply I/O bandwidth limits to low priority workloads using cgroup v2 `io.max` configuration
4. Expose status and Prometheus metrics for monitoring

## Architecture

The agent runs as a DaemonSet, ensuring one instance per worker node. It:
- Uses the Kubernetes API to list pods on its node
- Groups pods by the `group-id` label
- Discovers cgroup paths for low priority containers
- Applies read/write bandwidth limits to prevent interference with high priority workloads

## Setting Up AWS Credentials

Before deploying, you need to configure AWS credentials. We recommend using a `.env` file:

1. **Copy the example:**
   ```bash
   cp env.example ../.env
   ```

2. **Edit `.env` with your credentials from AWS Access Portal:**
   ```bash
   nano ../.env
   ```

3. **Load credentials:**
   ```bash
   ./load-aws-env.sh
   ```

See [ENV-FILE-SETUP.md](ENV-FILE-SETUP.md) for detailed instructions, or [AWS-CREDENTIALS-SETUP.md](AWS-CREDENTIALS-SETUP.md) for manual setup.

## Building

### Local Build

```bash
cd drc_io_agent
docker build -t drc-io-agent:latest .
```

### AWS ECR Build (Recommended for AWS)

See [aws-setup.md](aws-setup.md) for detailed AWS EKS setup instructions.

Quick start:
```bash
# Credentials from .env file are loaded automatically
./test-aws.sh  # This script builds, pushes, and deploys
```

Or manually:
```bash
# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build and push
docker build -t drc-io-agent:latest .
docker tag drc-io-agent:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/drc-io-agent:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/drc-io-agent:latest

# Update DaemonSet image
./update-image.sh
```

## Deployment

### Prerequisites

- Kubernetes cluster with cgroup v2 enabled
- Nodes must have `/sys/fs/cgroup` mounted
- Shared volume should be available at `/mnt/features` (or configure via `SHARED_MOUNT_PATH`)

### AWS EKS Deployment

**For AWS EKS, see [aws-setup.md](aws-setup.md) for complete setup instructions.**

Quick deployment on AWS:
```bash
# Automated test and deployment
./test-aws.sh

# Or manual deployment
kubectl apply -f daemonset.yaml
```

**AWS-Specific Requirements:**
- EKS cluster with OIDC provider enabled (for IRSA, optional)
- Node groups with sufficient I/O performance (gp3 EBS volumes recommended)
- ECR repository for container images
- Proper IAM permissions for ECR access

### Generic Kubernetes Deployment

```bash
kubectl apply -f daemonset.yaml
```

### Verify

```bash
# Check DaemonSet status
kubectl get daemonset drc-io-agent

# Check pod status
kubectl get pods -l app=drc-io-agent

# View logs
kubectl logs -l app=drc-io-agent

# Test endpoints (port forward first)
kubectl port-forward -l app=drc-io-agent 8080:8080
curl http://localhost:8080/status
```

## Configuration

The agent can be configured via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | `5` | Seconds between controller loop iterations |
| `SHARED_MOUNT_PATH` | `/mnt/features` | Path to shared volume mount |
| `READ_BANDWIDTH_LIMIT` | `200M` | Read bandwidth limit for low priority pods |
| `WRITE_BANDWIDTH_LIMIT` | `50M` | Write bandwidth limit for low priority pods |
| `METRICS_PORT` | `8080` | Port for metrics and status endpoints |
| `LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR) |

## Endpoints

### Health Check
```
GET /health
```
Returns `200 OK` if the agent is running.

### Status
```
GET /status
```
Returns JSON with:
- Pod counts by priority
- List of pods in each group
- Cgroups with limits applied
- Current configuration
- Error information

### Metrics (Prometheus)
```
GET /metrics
```
Returns Prometheus-formatted metrics:
- `drc_io_high_priority_pods` - Number of high priority pods
- `drc_io_low_priority_pods` - Number of low priority pods
- `drc_io_cgroups_with_limits` - Number of cgroups with limits
- `drc_io_controller_errors_total` - Total error count
- `drc_io_last_update_timestamp` - Last update timestamp

## Usage

### Labeling Pods

Pods must be labeled with `group-id=hp` (high priority) or `group-id=lp` (low priority):

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    group-id: hp  # or lp for low priority
```

### Example: Query Status

```bash
# Port forward to access endpoints
kubectl port-forward -l app=drc-io-agent 8080:8080

# Check status
curl http://localhost:8080/status | jq

# Get metrics
curl http://localhost:8080/metrics
```

## Troubleshooting

### Agent cannot find cgroup paths

- Ensure containers are running and have valid container IDs
- Check that the agent has `hostPID: true` and `privileged: true`
- Verify cgroup v2 is enabled: `mount | grep cgroup2`
- On AWS: Check that nodes are using AL2023 (cgroup v2) or AL2 with cgroup v2 enabled

### Agent cannot discover block device

- Ensure the shared volume is mounted at the configured path
- Check that the mount path exists: `ls -la /mnt/features`
- Verify `/proc/self/mountinfo` is readable
- On AWS: EBS volumes appear as NVMe devices (`/dev/nvme0n1`, etc.) - the agent handles this automatically

### I/O limits not being applied

- Check agent logs for permission errors
- Verify the cgroup path exists: `ls -la /sys/fs/cgroup/<path>/io.max`
- Ensure the block device format is correct (major:minor)
- On AWS: Verify EBS volumes are properly attached and formatted

### AWS-Specific Issues

**Cannot pull image from ECR:**
- Verify node group IAM role has `AmazonEC2ContainerRegistryReadOnly` policy
- Check image exists: `aws ecr describe-images --repository-name drc-io-agent`
- Verify image pull secrets if using private registry

**Pods stuck in Pending:**
- Check node group capacity
- Verify DaemonSet tolerations match node taints (if any)
- Check resource requests/limits

**Block device discovery fails on AWS:**
- EBS volumes on EKS use NVMe interface - agent handles this
- For EFS mounts, use EFS CSI driver instead of hostPath
- Verify volume is attached: `lsblk` in agent pod

See [aws-setup.md](aws-setup.md) for more AWS troubleshooting.

## Development

### Local Testing

```bash
# Install dependencies
pip install -r requirements.txt

# Run locally (requires Kubernetes access)
python main.py
```

### Code Structure

- `main.py` - Main controller loop and HTTP server
- `k8s_utils.py` - Kubernetes API interactions
- `cgroup_utils.py` - Cgroup path discovery and I/O limit management

## Security Considerations

- The agent requires `privileged: true` to write to cgroup files
- It uses `hostPID: true` to access host process information
- The service account has permissions to list pods cluster-wide
- Consider restricting RBAC permissions to specific namespaces in production

## Testing

### Test Pods

Deploy test workloads to verify the agent:

```bash
# Deploy test pods (high and low priority)
kubectl apply -f test-pods.yaml

# Check if agent detected them
kubectl port-forward -l app=drc-io-agent 8080:8080
curl http://localhost:8080/status | jq
```

### AWS Testing

Use the automated test script:

```bash
# Full test: build, push, deploy, verify
./test-aws.sh

# Cleanup test resources
./cleanup-aws.sh
```

## Integration

This component integrates with:
- **Track 2**: Kubernetes setup that labels pods and mounts shared volumes
- **Track 3**: Graph Neural Network service that measures latency improvements
- **Track 4**: Monitoring stack that scrapes `/metrics` (works with AWS CloudWatch, Prometheus, etc.)
- **Track 5**: Load generation that compares performance with/without limits

## AWS Resources

- [AWS EKS Setup Guide](aws-setup.md) - Complete AWS deployment instructions
- [Test Script](test-aws.sh) - Automated AWS testing
- [Cleanup Script](cleanup-aws.sh) - Clean up test resources

