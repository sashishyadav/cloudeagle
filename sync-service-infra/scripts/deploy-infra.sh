#!/bin/bash
# =============================================================================
# deploy-infra.sh — terraform plan/apply helper
# -----------------------------------------------------------------------------
# Wraps `terraform plan` and `apply` with sensible guardrails:
#   - Forces plan-review before apply
#   - Requires explicit confirmation for prod
#   - Captures plan output to a file for audit
#
# Usage:
#   ./deploy-infra.sh qa plan
#   ./deploy-infra.sh qa apply
#   ./deploy-infra.sh prod apply
# =============================================================================

set -euo pipefail

ENV="${1:?Usage: $0 <env> <plan|apply|destroy> [image-tag]}"
ACTION="${2:?Usage: $0 <env> <plan|apply|destroy> [image-tag]}"
IMAGE_TAG="${3:-latest}"

if [[ ! "$ENV" =~ ^(qa|staging|prod)$ ]]; then
    echo "❌ Invalid environment: $ENV (must be qa|staging|prod)"
    exit 1
fi

ENV_DIR="$(dirname "$0")/../terraform/envs/${ENV}"
cd "$ENV_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "  Terraform: $ACTION on $ENV"
echo "  Image tag: $IMAGE_TAG"
echo "═══════════════════════════════════════════════════════════════"

# Init if needed
[ ! -d ".terraform" ] && terraform init

case "$ACTION" in
    plan)
        terraform plan \
            -var="image_tag=${IMAGE_TAG}" \
            -out="plan.tfplan"
        echo ""
        echo "Plan saved to: ${ENV_DIR}/plan.tfplan"
        echo "Review, then run: $0 $ENV apply"
        ;;

    apply)
        if [ ! -f "plan.tfplan" ]; then
            echo "❌ No plan file found. Run '$0 $ENV plan' first."
            exit 1
        fi

        if [ "$ENV" = "prod" ]; then
            echo ""
            echo "⚠️  You are about to apply changes to PRODUCTION."
            read -p "Type 'DEPLOY TO PROD' to confirm: " CONFIRM
            if [ "$CONFIRM" != "DEPLOY TO PROD" ]; then
                echo "Aborted."
                exit 1
            fi
        fi

        terraform apply "plan.tfplan"
        rm -f plan.tfplan
        echo "✅ Apply complete"
        ;;

    destroy)
        if [ "$ENV" = "prod" ]; then
            echo "❌ Destroying prod via this script is disabled. Use AWS console with 2-person approval."
            exit 1
        fi
        terraform destroy -var="image_tag=${IMAGE_TAG}"
        ;;

    *)
        echo "❌ Unknown action: $ACTION"
        exit 1
        ;;
esac
