#!/bin/bash
# Helper script to update the DaemonSet image for AWS ECR

set -e

AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Error: Cannot determine AWS Account ID. Set AWS_ACCOUNT_ID or configure AWS CLI."
    exit 1
fi

ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/drc-io-agent:$IMAGE_TAG"

echo "Updating daemonset.yaml with image: $ECR_URI"

# Create backup
cp daemonset.yaml daemonset.yaml.bak

# Update image (handles various formats)
sed -i.tmp "s|image:.*drc-io-agent.*|image: $ECR_URI|g" daemonset.yaml

# Clean up temp file
rm -f daemonset.yaml.tmp

echo "✓ Updated daemonset.yaml"
echo "Backup saved as daemonset.yaml.bak"
echo ""
echo "To deploy: kubectl apply -f daemonset.yaml"

