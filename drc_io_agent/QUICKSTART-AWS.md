# Quick Start Guide - AWS EKS

This is a quick reference for deploying the DRC I/O Agent on AWS EKS.

## Prerequisites Checklist

- [ ] AWS CLI installed and configured
- [ ] `eksctl` installed (or AWS Console access)
- [ ] `kubectl` installed
- [ ] Docker installed
- [ ] EKS cluster created

## 1. Create EKS Cluster (if needed)

```bash
eksctl create cluster \
  --name drc-io-cluster \
  --region us-west-2 \
  --nodegroup-name worker-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --with-oidc
```

## 2. Run Automated Test Script

The test script will:
- Build the Docker image
- Push to ECR
- Deploy the DaemonSet
- Verify deployment
- Test endpoints

```bash
cd drc_io_agent
./test-aws.sh
```

## 3. Verify Deployment

```bash
# Check pods
kubectl get pods -l app=drc-io-agent

# View logs
kubectl logs -l app=drc-io-agent

# Check status
kubectl port-forward -l app=drc-io-agent 8080:8080
curl http://localhost:8080/status | jq
```

## 4. Deploy Test Workloads

```bash
# Deploy test pods
kubectl apply -f test-pods.yaml

# Verify agent detected them
curl http://localhost:8080/status | jq '.high_priority_pods_count, .low_priority_pods_count'
```

## 5. Cleanup (when done)

```bash
./cleanup-aws.sh
```

## Common Commands

```bash
# Update image in DaemonSet
./update-image.sh

# View agent metrics
kubectl port-forward -l app=drc-io-agent 8080:8080
curl http://localhost:8080/metrics

# Check which cgroups have limits
curl http://localhost:8080/status | jq '.cgroups_with_limits'
```

## Troubleshooting

If the test script fails:

1. **ECR access issues**: Verify AWS credentials and ECR permissions
2. **Cluster not found**: Check cluster name and region
3. **Image pull errors**: Ensure node group IAM role has ECR read permissions
4. **Pods not starting**: Check DaemonSet logs and node resources

See [aws-setup.md](aws-setup.md) for detailed troubleshooting.

## Next Steps

- Configure monitoring to scrape `/metrics` endpoint
- Deploy your actual workloads with `group-id=hp` and `group-id=lp` labels
- Integrate with your monitoring stack (CloudWatch, Prometheus, etc.)

