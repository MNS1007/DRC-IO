#!/bin/bash
# AWS EKS Test Script for DRC I/O Agent
# This script helps test the deployment on AWS EKS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-drc-io-cluster}"
NAMESPACE="${NAMESPACE:-default}"

echo -e "${GREEN}=== DRC I/O Agent AWS Test Script ===${NC}\n"

# Load AWS credentials from .env file if it exists
if [ -f "../.env" ]; then
    echo "Loading AWS credentials from ../.env..."
    export $(grep -v '^#' ../.env | grep -v '^$' | xargs)
    AWS_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
elif [ -f ".env" ]; then
    echo "Loading AWS credentials from .env..."
    export $(grep -v '^#' .env | grep -v '^$' | xargs)
    AWS_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
fi

# Function to check if command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

# Check prerequisites
echo "Checking prerequisites..."
check_command aws
check_command kubectl
check_command docker

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Cannot get AWS account ID. Check AWS credentials.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ AWS Account ID: $AWS_ACCOUNT_ID${NC}"

# Check if cluster exists
echo -e "\nChecking EKS cluster..."
if ! aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION &> /dev/null; then
    echo -e "${RED}Error: Cluster $CLUSTER_NAME not found in region $AWS_REGION${NC}"
    echo "Create cluster first or set CLUSTER_NAME environment variable"
    exit 1
fi

# Update kubeconfig
echo -e "${GREEN}✓ Cluster found. Updating kubeconfig...${NC}"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Check cluster connection
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to cluster${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to cluster${NC}"

# Build and push image
echo -e "\n=== Building and Pushing Docker Image ==="
ECR_REPO=drc-io-agent
ECR_URI=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO

# Check if ECR repo exists, create if not
if ! aws ecr describe-repositories --repository-names $ECR_REPO --region $AWS_REGION &> /dev/null; then
    echo "Creating ECR repository..."
    aws ecr create-repository --repository-name $ECR_REPO --region $AWS_REGION
fi

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin $ECR_URI

# Build image
echo "Building Docker image..."
cd "$(dirname "$0")"
docker build -t $ECR_REPO:latest .

# Tag and push
echo "Tagging and pushing image..."
docker tag $ECR_REPO:latest $ECR_URI:latest
docker push $ECR_URI:latest

echo -e "${GREEN}✓ Image pushed to $ECR_URI:latest${NC}"

# Update DaemonSet with ECR image
echo -e "\n=== Updating DaemonSet ==="
sed -i.bak "s|image:.*drc-io-agent.*|image: $ECR_URI:latest|g" daemonset.yaml
echo -e "${GREEN}✓ DaemonSet updated${NC}"

# Deploy
echo -e "\n=== Deploying DRC I/O Agent ==="
kubectl apply -f daemonset.yaml

# Wait for DaemonSet to be ready
echo "Waiting for DaemonSet to be ready..."
kubectl rollout status daemonset/drc-io-agent -n $NAMESPACE --timeout=120s

# Get pod names
PODS=$(kubectl get pods -l app=drc-io-agent -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    echo -e "${RED}Error: No pods found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ DaemonSet deployed. Pods: $PODS${NC}"

# Check pod status
echo -e "\n=== Checking Pod Status ==="
for pod in $PODS; do
    STATUS=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.phase}')
    if [ "$STATUS" == "Running" ]; then
        echo -e "${GREEN}✓ $pod: $STATUS${NC}"
    else
        echo -e "${YELLOW}⚠ $pod: $STATUS${NC}"
    fi
done

# Check logs
echo -e "\n=== Recent Logs (first pod) ==="
FIRST_POD=$(echo $PODS | cut -d' ' -f1)
kubectl logs $FIRST_POD -n $NAMESPACE --tail=20

# Test endpoints
echo -e "\n=== Testing Endpoints ==="
for pod in $PODS; do
    echo "Testing $pod..."
    
    # Port forward in background
    kubectl port-forward $pod 8080:8080 -n $NAMESPACE &
    PF_PID=$!
    sleep 2
    
    # Test health endpoint
    if curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo -e "${GREEN}✓ Health check passed${NC}"
    else
        echo -e "${RED}✗ Health check failed${NC}"
    fi
    
    # Test status endpoint
    if curl -s http://localhost:8080/status | grep -q "node_name"; then
        echo -e "${GREEN}✓ Status endpoint working${NC}"
        echo "Status:"
        curl -s http://localhost:8080/status | jq '.' 2>/dev/null || curl -s http://localhost:8080/status
    else
        echo -e "${RED}✗ Status endpoint failed${NC}"
    fi
    
    # Test metrics endpoint
    if curl -s http://localhost:8080/metrics | grep -q "drc_io"; then
        echo -e "${GREEN}✓ Metrics endpoint working${NC}"
    else
        echo -e "${RED}✗ Metrics endpoint failed${NC}"
    fi
    
    # Kill port forward
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
    
    break  # Test only first pod
done

# Deploy test pods
echo -e "\n=== Deploying Test Pods ==="
kubectl apply -f test-pods.yaml

echo "Waiting for test pods to be ready..."
sleep 10

# Check if agent detected test pods
echo -e "\n=== Verifying Pod Detection ==="
FIRST_POD=$(echo $PODS | cut -d' ' -f1)
kubectl port-forward $FIRST_POD 8080:8080 -n $NAMESPACE &
PF_PID=$!
sleep 2

STATUS=$(curl -s http://localhost:8080/status)
HP_COUNT=$(echo $STATUS | jq -r '.high_priority_pods_count' 2>/dev/null || echo "0")
LP_COUNT=$(echo $STATUS | jq -r '.low_priority_pods_count' 2>/dev/null || echo "0")

echo "High priority pods detected: $HP_COUNT"
echo "Low priority pods detected: $LP_COUNT"

if [ "$HP_COUNT" -gt 0 ] || [ "$LP_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Agent is detecting labeled pods${NC}"
else
    echo -e "${YELLOW}⚠ No labeled pods detected yet. This is normal if test pods just started.${NC}"
fi

kill $PF_PID 2>/dev/null || true

echo -e "\n${GREEN}=== Test Complete ===${NC}"
echo "To view logs: kubectl logs -l app=drc-io-agent -n $NAMESPACE"
echo "To check status: kubectl port-forward -l app=drc-io-agent 8080:8080 -n $NAMESPACE"
echo "Then visit: http://localhost:8080/status"

