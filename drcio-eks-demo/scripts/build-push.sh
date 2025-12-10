#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE_TAG="v1.0.0"

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      Building and Pushing Docker Images to ECR        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Registry: $ECR_REGISTRY"
echo "Tag: $IMAGE_TAG"
echo ""

check_docker() {
    echo -e "${YELLOW}[1/6]${NC} Checking Docker..."
    if ! docker info > /dev/null 2>&1; then
        echo -e "${RED}✗ Docker is not running${NC}"
        echo "Please start Docker and try again"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker is running${NC}"
    echo ""
}

login_ecr() {
    echo -e "${YELLOW}[2/6]${NC} Logging into Amazon ECR..."

    aws ecr get-login-password --region "${AWS_REGION}" | \
        docker login --username AWS --password-stdin "${ECR_REGISTRY}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Logged into ECR${NC}"
    else
        echo -e "${RED}✗ ECR login failed${NC}"
        exit 1
    fi
    echo ""
}

create_repos() {
    echo -e "${YELLOW}[3/6]${NC} Creating ECR repositories..."

    for repo in hp-service lp-batch drcio-controller; do
        echo -n "  Checking $repo... "

        if aws ecr describe-repositories --repository-names "${repo}" --region "${AWS_REGION}" > /dev/null 2>&1; then
            echo -e "${GREEN}exists${NC}"
        else
            aws ecr create-repository \
                --repository-name "${repo}" \
                --region "${AWS_REGION}" \
                --image-scanning-configuration scanOnPush=true \
                --encryption-configuration encryptionType=AES256 > /dev/null

            echo -e "${GREEN}created${NC}"
        fi
    done

    echo -e "${GREEN}✓ All repositories ready${NC}"
    echo ""
}

build_hp_service() {
    echo -e "${YELLOW}[4/6]${NC} Building HP Service (GNN Fraud Detection)..."
    pushd docker/hp-service > /dev/null

    echo "  Building Docker image..."
    docker build -t "${ECR_REGISTRY}/hp-service:${IMAGE_TAG}" . --no-cache

    echo "  Pushing to ECR..."
    docker push "${ECR_REGISTRY}/hp-service:${IMAGE_TAG}"

    docker tag "${ECR_REGISTRY}/hp-service:${IMAGE_TAG}" "${ECR_REGISTRY}/hp-service:latest"
    docker push "${ECR_REGISTRY}/hp-service:latest"

    popd > /dev/null
    echo -e "${GREEN}✓ HP Service built and pushed${NC}"
    echo ""
}

build_lp_batch() {
    echo -e "${YELLOW}[5/6]${NC} Building LP Batch Job (I/O Stress)..."
    pushd docker/lp-batch > /dev/null

    echo "  Building Docker image..."
    docker build -t "${ECR_REGISTRY}/lp-batch:${IMAGE_TAG}" . --no-cache

    echo "  Pushing to ECR..."
    docker push "${ECR_REGISTRY}/lp-batch:${IMAGE_TAG}"

    docker tag "${ECR_REGISTRY}/lp-batch:${IMAGE_TAG}" "${ECR_REGISTRY}/lp-batch:latest"
    docker push "${ECR_REGISTRY}/lp-batch:latest"

    popd > /dev/null
    echo -e "${GREEN}✓ LP Batch built and pushed${NC}"
    echo ""
}

build_drcio() {
    echo -e "${YELLOW}[6/6]${NC} Building DRC-IO Controller..."
    pushd docker/drcio > /dev/null

    echo "  Building Docker image..."
    docker build -t "${ECR_REGISTRY}/drcio-controller:${IMAGE_TAG}" . --no-cache

    echo "  Pushing to ECR..."
    docker push "${ECR_REGISTRY}/drcio-controller:${IMAGE_TAG}"

    docker tag "${ECR_REGISTRY}/drcio-controller:${IMAGE_TAG}" "${ECR_REGISTRY}/drcio-controller:latest"
    docker push "${ECR_REGISTRY}/drcio-controller:latest"

    popd > /dev/null
    echo -e "${GREEN}✓ DRC-IO Controller built and pushed${NC}"
    echo ""
}

update_manifests() {
    echo "Updating Kubernetes manifests with image URIs..."

    find kubernetes/ -name "*.yaml" -type f | while read -r file; do
        sed -i.bak "s|IMAGE_REGISTRY|${ECR_REGISTRY}|g" "$file"
        sed -i.bak "s|IMAGE_TAG|${IMAGE_TAG}|g" "$file"
    done

    find kubernetes/ -name "*.yaml.bak" -delete
    echo -e "${GREEN}✓ Manifests updated${NC}"
}

save_build_info() {
    cat > build-info.txt <<EOF
Docker Build Information
========================

Build Date: $(date)
AWS Account: ${AWS_ACCOUNT_ID}
Registry: ${ECR_REGISTRY}
Image Tag: ${IMAGE_TAG}

Images:
-------
HP Service:        ${ECR_REGISTRY}/hp-service:${IMAGE_TAG}
LP Batch:          ${ECR_REGISTRY}/lp-batch:${IMAGE_TAG}
DRC-IO Controller: ${ECR_REGISTRY}/drcio-controller:${IMAGE_TAG}

Next Steps:
-----------
1. Deploy to Kubernetes: ./scripts/deploy-all.sh
2. Verify deployment: kubectl get pods -n fraud-detection

To rebuild:
-----------
./scripts/build-push.sh

To clean up images:
-------------------
docker image rm ${ECR_REGISTRY}/hp-service:${IMAGE_TAG}
docker image rm ${ECR_REGISTRY}/lp-batch:${IMAGE_TAG}
docker image rm ${ECR_REGISTRY}/drcio-controller:${IMAGE_TAG}
EOF

    echo -e "${GREEN}✓ Build info saved to build-info.txt${NC}"
}

main() {
    check_docker
    login_ecr
    create_repos
    build_hp_service
    build_lp_batch
    build_drcio
    update_manifests
    save_build_info

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           ✅ All Images Built and Pushed!             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Images:${NC}"
    echo "  HP Service:        ${ECR_REGISTRY}/hp-service:${IMAGE_TAG}"
    echo "  LP Batch:          ${ECR_REGISTRY}/lp-batch:${IMAGE_TAG}"
    echo "  DRC-IO Controller: ${ECR_REGISTRY}/drcio-controller:${IMAGE_TAG}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Deploy to Kubernetes: cd scripts && ./deploy-all.sh"
    echo "  2. Verify: kubectl get pods -n fraud-detection"
    echo ""
}

main
