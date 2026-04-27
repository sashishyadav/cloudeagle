#!/bin/bash
# =============================================================================
# deploy-rolling.sh
# -----------------------------------------------------------------------------
# Rolling deploy for QA. One instance at a time, quick iteration.
#
# Usage:
#   ./deploy-rolling.sh <environment> <image-tag>
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:?Environment required}"
IMAGE_TAG="${2:?Image tag required}"
SERVICE_NAME="sync-service"
GCP_PROJECT="${GCP_PROJECT:-acme-sync-service}"
GCP_REGION="${GCP_REGION:-us-central1}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Rolling Deploy"
echo "  Service     : $SERVICE_NAME"
echo "  Environment : $ENVIRONMENT"
echo "  Image tag   : $IMAGE_TAG"
echo "═══════════════════════════════════════════════════════════════"

# ── Create new instance template ────────────────────────────────────────────
TEMPLATE_NAME="${SERVICE_NAME}-${ENVIRONMENT}-${IMAGE_TAG}"
echo ""
echo "▸ Creating instance template: $TEMPLATE_NAME"
gcloud compute instance-templates create "$TEMPLATE_NAME" \
    --project="$GCP_PROJECT" \
    --source-instance-template="${SERVICE_NAME}-${ENVIRONMENT}-template-base" \
    --metadata="IMAGE_TAG=${IMAGE_TAG},ENVIRONMENT=${ENVIRONMENT}" \
    --quiet

# ── Start rolling update ────────────────────────────────────────────────────
echo ""
echo "▸ Rolling update (max-unavailable=1, max-surge=1)..."
gcloud compute instance-groups managed rolling-action start-update \
    "${SERVICE_NAME}-${ENVIRONMENT}" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --version="template=${TEMPLATE_NAME}" \
    --max-unavailable=1 \
    --max-surge=1 \
    --quiet

echo ""
echo "▸ Waiting for rollout to complete..."
gcloud compute instance-groups managed wait-until \
    "${SERVICE_NAME}-${ENVIRONMENT}" \
    --version-target-reached \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT"

echo ""
echo "✅ Rolling deploy complete — $ENVIRONMENT running image $IMAGE_TAG"
