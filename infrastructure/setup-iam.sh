#!/bin/bash
##############################################################################
# IAM User Setup for DRC-IO Demo
#
# This script creates an IAM user with the necessary permissions to run
# the DRC-IO EKS demo.
#
# Usage:
#   ./setup-iam.sh [USERNAME]
#
# If USERNAME is not provided, it will use your current IAM user.
##############################################################################

set -e
set -o pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# Main
##############################################################################

log_section "IAM Setup for DRC-IO Demo"

# Get current user
CURRENT_USER=$(aws iam get-user --query 'User.UserName' --output text 2>/dev/null || echo "")
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

# Determine target user
if [ -n "$1" ]; then
    TARGET_USER="$1"
    log_info "Setting up IAM user: $TARGET_USER"
else
    if [ -z "$CURRENT_USER" ]; then
        log_error "Cannot determine current IAM user and no username provided"
        log_info "Usage: $0 [USERNAME]"
        exit 1
    fi
    TARGET_USER="$CURRENT_USER"
    log_info "Setting up permissions for current user: $TARGET_USER"
fi

log_info "AWS Account: $ACCOUNT_ID"

# Check if policy already exists
POLICY_NAME="DRC-IO-EKS-Demo-Policy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo ""
log_section "Creating IAM Policy"

if aws iam get-policy --policy-arn "$POLICY_ARN" &> /dev/null; then
    log_warning "Policy already exists: $POLICY_NAME"

    read -p "Update existing policy? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        # Create a new version
        log_info "Creating new policy version..."

        aws iam create-policy-version \
            --policy-arn "$POLICY_ARN" \
            --policy-document file://"$SCRIPT_DIR/iam-policy.json" \
            --set-as-default

        log_success "Policy updated"
    fi
else
    log_info "Creating policy: $POLICY_NAME"

    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://"$SCRIPT_DIR/iam-policy.json" \
        --description "Permissions for DRC-IO EKS demo"

    log_success "Policy created"
fi

# Attach policy to user
echo ""
log_section "Attaching Policy to User"

if aws iam list-attached-user-policies --user-name "$TARGET_USER" | grep -q "$POLICY_NAME"; then
    log_success "Policy already attached to user: $TARGET_USER"
else
    log_info "Attaching policy to user: $TARGET_USER"

    aws iam attach-user-policy \
        --user-name "$TARGET_USER" \
        --policy-arn "$POLICY_ARN"

    log_success "Policy attached"
fi

# Summary
echo ""
log_section "✅ IAM Setup Complete"

echo ""
echo "User: $TARGET_USER"
echo "Policy: $POLICY_NAME"
echo "Policy ARN: $POLICY_ARN"
echo ""
echo "📝 Next Steps:"
echo "  1. Verify permissions:"
echo "     aws sts get-caller-identity"
echo ""
echo "  2. Run infrastructure setup:"
echo "     cd infrastructure && ./setup.sh"
echo ""
log_warning "Note: It may take a few seconds for IAM changes to propagate"
echo ""
