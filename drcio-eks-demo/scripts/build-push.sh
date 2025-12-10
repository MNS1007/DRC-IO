#!/bin/bash
##############################################################################
# Docker Image Build and Push Script for DRC-IO
#
# This script builds Docker images for all DRC-IO components and pushes
# them to Amazon ECR (Elastic Container Registry).
#
# Prerequisites:
#   - Docker installed and running
#   - AWS CLI configured
#   - AWS ECR repositories created
#
# Usage:
#   ./build-push.sh [OPTIONS]
#
# Options:
#   --skip-build    Skip building images
#   --skip-push     Skip pushing images
#   --service NAME  Build only specific service (hp-service|lp-batch|drcio)
##############################################################################

set -e
set -u
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Options
SKIP_BUILD=false
SKIP_PUSH=false
SPECIFIC_SERVICE=""

# Services to build
declare -A SERVICES=(
    ["hp-service"]="docker/hp-service"
    ["lp-batch"]="docker/lp-batch"
    ["drcio"]="docker/drcio"
)

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}ℹ ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
}

##############################################################################
# Parse Arguments
##############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-push)
                SKIP_PUSH=true
                shift
                ;;
            --service)
                SPECIFIC_SERVICE="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --skip-build         Skip building images"
                echo "  --skip-push          Skip pushing images"
                echo "  --service NAME       Build only specific service"
                echo "  --help, -h           Show this help message"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

##############################################################################
# ECR Setup
##############################################################################

create_ecr_repositories() {
    log_section "Creating ECR Repositories"

    for service in "${!SERVICES[@]}"; do
        local repo_name="drcio/${service}"

        log_info "Checking repository: $repo_name"

        if aws ecr describe-repositories \
            --repository-names "$repo_name" \
            --region "$AWS_REGION" &> /dev/null; then
            log_success "Repository exists: $repo_name"
        else
            log_info "Creating repository: $repo_name"
            aws ecr create-repository \
                --repository-name "$repo_name" \
                --region "$AWS_REGION" \
                --image-scanning-configuration scanOnPush=true \
                --tags Key=Project,Value=drc-io Key=ManagedBy,Value=script

            log_success "Repository created: $repo_name"
        fi
    done
}

login_to_ecr() {
    log_section "Logging in to ECR"

    log_info "Authenticating with ECR..."

    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_REGISTRY"

    log_success "Successfully logged in to ECR"
}

##############################################################################
# Docker Build
##############################################################################

build_image() {
    local service=$1
    local service_dir=$2
    local image_name="${ECR_REGISTRY}/drcio/${service}:${IMAGE_TAG}"

    log_section "Building Image: $service"

    log_info "Service: $service"
    log_info "Directory: $service_dir"
    log_info "Image: $image_name"

    # Navigate to service directory
    cd "$PROJECT_ROOT/$service_dir"

    # Build image
    log_info "Running docker build..."
    docker build \
        --tag "$image_name" \
        --tag "${ECR_REGISTRY}/drcio/${service}:$(date +%Y%m%d-%H%M%S)" \
        --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --build-arg VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
        .

    log_success "Image built successfully: $image_name"

    # Return to project root
    cd "$PROJECT_ROOT"
}

build_all_images() {
    log_section "Building All Images"

    for service in "${!SERVICES[@]}"; do
        if [ -n "$SPECIFIC_SERVICE" ] && [ "$service" != "$SPECIFIC_SERVICE" ]; then
            log_info "Skipping $service (not requested)"
            continue
        fi

        build_image "$service" "${SERVICES[$service]}"
    done
}

##############################################################################
# Docker Push
##############################################################################

push_image() {
    local service=$1
    local image_name="${ECR_REGISTRY}/drcio/${service}:${IMAGE_TAG}"

    log_section "Pushing Image: $service"

    log_info "Pushing $image_name..."

    docker push "$image_name"

    log_success "Image pushed successfully: $image_name"

    # Also push timestamped tag
    local timestamped_tag="${ECR_REGISTRY}/drcio/${service}:$(date +%Y%m%d-%H%M%S)"
    if docker image inspect "$timestamped_tag" &> /dev/null; then
        docker push "$timestamped_tag" || log_warning "Failed to push timestamped tag"
    fi
}

push_all_images() {
    log_section "Pushing All Images"

    for service in "${!SERVICES[@]}"; do
        if [ -n "$SPECIFIC_SERVICE" ] && [ "$service" != "$SPECIFIC_SERVICE" ]; then
            log_info "Skipping $service (not requested)"
            continue
        fi

        push_image "$service"
    done
}

##############################################################################
# Update Kubernetes Manifests
##############################################################################

update_manifests() {
    log_section "Updating Kubernetes Manifests"

    log_info "Updating image references in manifests..."

    # Update deployment files with ECR image URLs
    find "$PROJECT_ROOT/kubernetes" -name "*.yaml" -type f -print0 | while IFS= read -r -d '' file; do
        if grep -q "<AWS_ACCOUNT_ID>" "$file" 2>/dev/null; then
            log_info "Updating: $file"

            # Create backup
            cp "$file" "$file.bak"

            # Replace placeholder with actual account ID
            sed -i.tmp "s/<AWS_ACCOUNT_ID>/${AWS_ACCOUNT_ID}/g" "$file"
            rm -f "$file.tmp"

            log_success "Updated: $file"
        fi
    done

    log_info "Backup files created with .bak extension"
}

##############################################################################
# Summary
##############################################################################

print_summary() {
    log_section "✅ Build and Push Complete"

    echo ""
    echo "📦 Built and pushed images:"
    for service in "${!SERVICES[@]}"; do
        if [ -n "$SPECIFIC_SERVICE" ] && [ "$service" != "$SPECIFIC_SERVICE" ]; then
            continue
        fi
        echo "  - ${ECR_REGISTRY}/drcio/${service}:${IMAGE_TAG}"
    done

    echo ""
    echo "📝 Next Steps:"
    echo "  1. Update Kubernetes manifests (if not done automatically):"
    echo "     Find and replace <AWS_ACCOUNT_ID> with: $AWS_ACCOUNT_ID"
    echo ""
    echo "  2. Deploy workloads:"
    echo "     cd scripts && ./deploy-all.sh"
    echo ""
    echo "  3. Verify deployments:"
    echo "     kubectl get pods -A"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    parse_args "$@"

    log_section "🐳 DRC-IO Docker Build and Push"

    log_info "AWS Account: $AWS_ACCOUNT_ID"
    log_info "AWS Region: $AWS_REGION"
    log_info "ECR Registry: $ECR_REGISTRY"
    log_info "Image Tag: $IMAGE_TAG"

    if [ -n "$SPECIFIC_SERVICE" ]; then
        log_info "Building only: $SPECIFIC_SERVICE"
    fi

    # Create ECR repositories
    create_ecr_repositories

    # Login to ECR
    login_to_ecr

    # Build images
    if [ "$SKIP_BUILD" = false ]; then
        build_all_images
    else
        log_warning "Skipping image builds"
    fi

    # Push images
    if [ "$SKIP_PUSH" = false ]; then
        push_all_images
    else
        log_warning "Skipping image pushes"
    fi

    # Update manifests
    update_manifests

    # Print summary
    print_summary
}

# Run main function
main "$@"
