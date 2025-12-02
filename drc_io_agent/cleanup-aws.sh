#!/bin/bash
# Cleanup script for AWS EKS test resources

set -e

NAMESPACE="${NAMESPACE:-default}"

echo "Cleaning up DRC I/O Agent test resources..."

# Delete test pods
echo "Deleting test pods..."
kubectl delete pod test-high-priority test-low-priority-1 test-low-priority-2 -n $NAMESPACE --ignore-not-found=true

# Delete DaemonSet
echo "Deleting DaemonSet..."
kubectl delete -f daemonset.yaml --ignore-not-found=true

# Delete RBAC resources
echo "Cleaning up RBAC..."
kubectl delete clusterrolebinding drc-io-agent --ignore-not-found=true
kubectl delete clusterrole drc-io-agent --ignore-not-found=true
kubectl delete serviceaccount drc-io-agent -n $NAMESPACE --ignore-not-found=true

echo "Cleanup complete!"
echo ""
echo "Note: ECR image and EKS cluster are not deleted."
echo "To delete ECR image:"
echo "  aws ecr delete-repository --repository-name drc-io-agent --force"
echo ""
echo "To delete EKS cluster:"
echo "  eksctl delete cluster --name drc-io-cluster"

