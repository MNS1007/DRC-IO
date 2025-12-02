# AWS EKS Setup Guide for DRC I/O Agent

This guide covers deploying the DRC I/O Agent on Amazon EKS.

## Prerequisites

- AWS CLI installed and configured
- `eksctl` installed (or use AWS Console/CloudFormation)
- `kubectl` installed and configured
- Docker installed for building images
- AWS ECR access (or another container registry)

## 1. EKS Cluster Setup

### Option A: Using eksctl (Recommended)

```bash
# Create EKS cluster with required settings
eksctl create cluster \
  --name drc-io-cluster \
  --region us-west-2 \
  --nodegroup-name worker-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed \
  --with-oidc \
  --enable-ssm
```

### Option B: Using AWS Console

1. Go to EKS Console → Create Cluster
2. Enable OIDC provider (for IRSA)
3. Create node group with:
   - Instance type: t3.medium or larger
   - AMI type: AL2_x86_64 (Amazon Linux 2)
   - Enable SSH access if needed

## 2. Build and Push Docker Image to ECR

```bash
# Set variables
AWS_REGION=us-west-2
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO=drc-io-agent

# Create ECR repository
aws ecr create-repository \
  --repository-name $ECR_REPO \
  --region $AWS_REGION

# Get login token
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build image
cd drc_io_agent
docker build -t $ECR_REPO:latest .

# Tag and push
docker tag $ECR_REPO:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
```

## 3. Configure IAM Roles for Service Accounts (IRSA)

The agent needs permissions to list pods. For AWS EKS, use IRSA:

```bash
# Create IAM policy
cat > drc-io-agent-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Create IAM policy (optional - Kubernetes RBAC handles pod listing)
# aws iam create-policy \
#   --policy-name DRC-IO-Agent-Policy \
#   --policy-document file://drc-io-agent-policy.json

# Get cluster OIDC issuer URL
OIDC_ID=$(aws eks describe-cluster --name drc-io-cluster --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

# Create IAM role and attach to service account
eksctl create iamserviceaccount \
  --cluster=drc-io-cluster \
  --namespace=default \
  --name=drc-io-agent \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/DRC-IO-Agent-Policy \
  --override-existing-serviceaccounts \
  --approve
```

**Note:** For this agent, IRSA is optional since we only need Kubernetes API permissions (handled by RBAC). IRSA is included for future AWS service integrations.

## 4. Update DaemonSet for AWS

Update the image in `daemonset.yaml`:

```yaml
image: $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/drc-io-agent:latest
```

Or use the provided script to update it automatically.

## 5. Create EBS Volume for Shared Storage (Optional)

If you need persistent shared storage:

```bash
# Create EBS volume
VOLUME_ID=$(aws ec2 create-volume \
  --availability-zone us-west-2a \
  --size 10 \
  --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=drc-io-shared}]' \
  --query 'VolumeId' --output text)

# Note: You'll need to attach this to nodes or use EBS CSI driver with PVC
```

For testing, a hostPath volume is sufficient. For production, consider:
- EBS CSI driver with PersistentVolumeClaim
- EFS CSI driver for shared access across nodes
- FSx for Lustre for high-performance shared storage

## 6. Deploy the Agent

```bash
# Update image in daemonset.yaml (or use sed)
sed -i.bak "s|image: drc-io-agent:latest|image: $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/drc-io-agent:latest|g" daemonset.yaml

# Deploy
kubectl apply -f daemonset.yaml

# Verify
kubectl get daemonset drc-io-agent
kubectl get pods -l app=drc-io-agent
```

## 7. AWS-Specific Considerations

### Block Device Discovery

On AWS EKS nodes:
- EBS volumes appear as `/dev/nvme0n1`, `/dev/nvme1n1`, etc.
- The agent will discover the major:minor device ID automatically
- For EBS-backed volumes, the device format is typically `259:0`, `259:1`, etc.

### Node Groups

Ensure your node groups have:
- Sufficient I/O performance (gp3 EBS volumes recommended)
- Network bandwidth for shared storage access
- Instance types that support the required I/O operations

### Monitoring Integration

The agent exposes Prometheus metrics that can be scraped by:
- AWS CloudWatch Container Insights
- Prometheus deployed in EKS
- AWS Managed Prometheus

## 8. Testing on AWS

See `test-aws.sh` for automated testing scripts.

## Troubleshooting AWS-Specific Issues

### Issue: Cannot access ECR

```bash
# Verify AWS credentials
aws sts get-caller-identity

# Re-authenticate ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
```

### Issue: Pods cannot pull image

- Check node group IAM role has ECR read permissions
- Verify image exists: `aws ecr describe-images --repository-name drc-io-agent`
- Check image pull policy in DaemonSet

### Issue: Cannot write to cgroup files

- Verify nodes are using cgroup v2 (Amazon Linux 2023 uses v2 by default)
- Check DaemonSet has `privileged: true`
- Verify `/sys/fs/cgroup` is mounted correctly

### Issue: Cannot discover block device

- Ensure shared volume is mounted on nodes
- Check `/proc/self/mountinfo` in agent pod
- For EBS volumes, verify volume is attached and formatted

## Cost Optimization

- Use Spot Instances for test workloads
- Right-size node groups based on actual usage
- Use gp3 EBS volumes (cheaper than gp2 with better performance)
- Consider Fargate for agent pods (if supported with required permissions)

