#!/bin/bash
# =============================================================================
# deploy-blue-green.sh
# -----------------------------------------------------------------------------
# Standalone blue/green deploy script for sync-service.
# Can be called from Jenkins OR run manually for emergency deploys.
#
# Usage:
#   ./deploy-blue-green.sh <environment> <image-tag>
#
# Example:
#   ./deploy-blue-green.sh prod abc123-42
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:?Environment required (staging|prod)}"
IMAGE_TAG="${2:?Image tag required}"
SERVICE_NAME="sync-service"
GCP_PROJECT="${GCP_PROJECT:-acme-sync-service}"
GCP_REGION="${GCP_REGION:-us-central1}"

if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "prod" ]]; then
    echo "❌ Blue/green is only for staging or prod (got: $ENVIRONMENT)"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Blue/Green Deploy"
echo "  Service     : $SERVICE_NAME"
echo "  Environment : $ENVIRONMENT"
echo "  Image tag   : $IMAGE_TAG"
echo "═══════════════════════════════════════════════════════════════"

# ── Determine active / idle colors ──────────────────────────────────────────
echo ""
echo "▸ Determining active color..."
ACTIVE=$(gcloud compute backend-services describe \
    "${SERVICE_NAME}-${ENVIRONMENT}-lb" \
    --global --project="$GCP_PROJECT" \
    --format='value(backends[0].group)' | \
    grep -oE '(blue|green)' | head -1 || echo 'blue')

IDLE=$([ "$ACTIVE" = "blue" ] && echo "green" || echo "blue")

echo "  Active : $ACTIVE"
echo "  Idle   : $IDLE (will be updated)"

# ── Create new instance template ────────────────────────────────────────────
TEMPLATE_NAME="${SERVICE_NAME}-${ENVIRONMENT}-${IDLE}-${IMAGE_TAG}"
echo ""
echo "▸ Creating instance template: $TEMPLATE_NAME"
gcloud compute instance-templates create "$TEMPLATE_NAME" \
    --project="$GCP_PROJECT" \
    --source-instance-template="${SERVICE_NAME}-${ENVIRONMENT}-template-base" \
    --metadata="IMAGE_TAG=${IMAGE_TAG},ENVIRONMENT=${ENVIRONMENT}" \
    --quiet

# ── Update idle MIG ─────────────────────────────────────────────────────────
echo ""
echo "▸ Updating idle instance group to new template..."
gcloud compute instance-groups managed set-instance-template \
    "${SERVICE_NAME}-${ENVIRONMENT}-${IDLE}" \
    --template="$TEMPLATE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --quiet

# ── Replace idle instances ──────────────────────────────────────────────────
echo ""
echo "▸ Replacing idle instances (this takes 2-5 minutes)..."
gcloud compute instance-groups managed rolling-action replace \
    "${SERVICE_NAME}-${ENVIRONMENT}-${IDLE}" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --max-unavailable=0 \
    --max-surge=2 \
    --quiet

# ── Wait for stability ──────────────────────────────────────────────────────
echo ""
echo "▸ Waiting for idle group to reach target version..."
gcloud compute instance-groups managed wait-until \
    "${SERVICE_NAME}-${ENVIRONMENT}-${IDLE}" \
    --version-target-reached \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT"

echo ""
echo "✅ Idle group ($IDLE) is healthy with image $IMAGE_TAG"
echo "   Next step: run smoke tests, then ./finalize-blue-green.sh $ENVIRONMENT $IDLE"

# Persist for downstream scripts
echo "$IDLE" > "/tmp/new_color_${ENVIRONMENT}"
