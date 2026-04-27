#!/bin/bash
# =============================================================================
# rollback.sh
# -----------------------------------------------------------------------------
# Manual rollback helper. Restores previous version by:
#   - staging/prod: flipping LB backend back to old (still-warm) color
#   - qa: rolling update to previous image template
#
# Usage:
#   ./rollback.sh <environment>                    # flip to previous color
#   ./rollback.sh <environment> <target-tag>       # roll back to specific tag
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:?Environment required}"
TARGET_TAG="${2:-}"
SERVICE_NAME="sync-service"
GCP_PROJECT="${GCP_PROJECT:-acme-sync-service}"
GCP_REGION="${GCP_REGION:-us-central1}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Rollback"
echo "  Environment : $ENVIRONMENT"
echo "  Target tag  : ${TARGET_TAG:-<previous color>}"
echo "═══════════════════════════════════════════════════════════════"

# ── Confirm with user unless AUTO_CONFIRM=1 ─────────────────────────────────
if [ "${AUTO_CONFIRM:-0}" != "1" ]; then
    read -p "⚠️  Are you sure you want to rollback $ENVIRONMENT? (yes/NO) " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

if [ "$ENVIRONMENT" = "staging" ] || [ "$ENVIRONMENT" = "prod" ]; then
    echo ""
    echo "▸ Blue/green rollback: flipping LB to previous color"

    CURRENT=$(gcloud compute backend-services describe \
        "${SERVICE_NAME}-${ENVIRONMENT}-lb" \
        --global --project="$GCP_PROJECT" \
        --format='value(backends[0].group)' | \
        grep -oE '(blue|green)' | head -1)

    PREV=$([ "$CURRENT" = "blue" ] && echo "green" || echo "blue")
    echo "  Current : $CURRENT"
    echo "  Rolling back to : $PREV"

    # Make sure previous MIG has instances (if it was torn down, we need to rebuild)
    PREV_SIZE=$(gcloud compute instance-groups managed describe \
        "${SERVICE_NAME}-${ENVIRONMENT}-${PREV}" \
        --region="$GCP_REGION" \
        --project="$GCP_PROJECT" \
        --format='value(targetSize)')

    if [ "$PREV_SIZE" = "0" ]; then
        echo "⚠️  Previous color was already torn down. Scaling back up..."
        gcloud compute instance-groups managed resize \
            "${SERVICE_NAME}-${ENVIRONMENT}-${PREV}" \
            --size=6 \
            --region="$GCP_REGION" \
            --project="$GCP_PROJECT" \
            --quiet

        gcloud compute instance-groups managed wait-until \
            "${SERVICE_NAME}-${ENVIRONMENT}-${PREV}" \
            --stable \
            --region="$GCP_REGION" \
            --project="$GCP_PROJECT"
    fi

    gcloud compute backend-services update "${SERVICE_NAME}-${ENVIRONMENT}-lb" \
        --global --project="$GCP_PROJECT" --no-backends --quiet

    gcloud compute backend-services add-backend "${SERVICE_NAME}-${ENVIRONMENT}-lb" \
        --global \
        --instance-group="${SERVICE_NAME}-${ENVIRONMENT}-${PREV}" \
        --instance-group-region="$GCP_REGION" \
        --project="$GCP_PROJECT" \
        --quiet

    echo ""
    echo "✅ Rollback complete — traffic now on $PREV"

else
    # QA: rolling rollback
    if [ -z "$TARGET_TAG" ]; then
        echo "❌ Tag required for QA rollback (previous template name)"
        exit 1
    fi

    echo ""
    echo "▸ QA rolling rollback to template: ${SERVICE_NAME}-qa-${TARGET_TAG}"
    gcloud compute instance-groups managed rolling-action start-update \
        "${SERVICE_NAME}-qa" \
        --region="$GCP_REGION" \
        --project="$GCP_PROJECT" \
        --version="template=${SERVICE_NAME}-qa-${TARGET_TAG}" \
        --max-unavailable=1 \
        --max-surge=1 \
        --quiet

    echo "✅ Rollback initiated — monitor with 'gcloud compute instance-groups managed describe ...'"
fi
