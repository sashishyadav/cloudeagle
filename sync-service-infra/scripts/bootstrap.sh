#!/bin/bash
# =============================================================================
# bootstrap.sh — one-time setup of GCP prerequisites
# -----------------------------------------------------------------------------
# Run this ONCE before using Terraform:
#   - Creates GCP projects for each env
#   - Creates the Terraform state bucket
#   - Enables required APIs
#   - Creates a Jenkins deploy service account
# =============================================================================

set -euo pipefail

ORG_ID="${ORG_ID:?Set your GCP organization ID}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:?Set your billing account ID}"
STATE_BUCKET="sync-service-terraform-state"

ENVIRONMENTS=("qa" "staging" "prod")
REQUIRED_APIS=(
    "compute.googleapis.com"
    "secretmanager.googleapis.com"
    "artifactregistry.googleapis.com"
    "cloudbuild.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "cloudtrace.googleapis.com"
    "iap.googleapis.com"
    "iamcredentials.googleapis.com"
)

echo "═══════════════════════════════════════════════════════════════"
echo "  sync-service infra bootstrap"
echo "═══════════════════════════════════════════════════════════════"

# ─── Create Terraform state bucket (one for all envs) ───────────────────────
STATE_PROJECT="sync-service-infra-shared"

if ! gcloud projects describe "$STATE_PROJECT" &>/dev/null; then
    echo "▸ Creating shared infra project: $STATE_PROJECT"
    gcloud projects create "$STATE_PROJECT" \
        --organization="$ORG_ID" \
        --set-as-default

    gcloud beta billing projects link "$STATE_PROJECT" \
        --billing-account="$BILLING_ACCOUNT"
fi

if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$STATE_PROJECT" &>/dev/null; then
    echo "▸ Creating Terraform state bucket"
    gcloud storage buckets create "gs://${STATE_BUCKET}" \
        --project="$STATE_PROJECT" \
        --location=asia-south1 \
        --uniform-bucket-level-access \
        --public-access-prevention
    gcloud storage buckets update "gs://${STATE_BUCKET}" \
        --versioning
fi

# ─── Create per-env projects + enable APIs ──────────────────────────────────
for env in "${ENVIRONMENTS[@]}"; do
    PROJECT_ID="sync-service-${env}"
    echo ""
    echo "▸ Setting up project: $PROJECT_ID"

    if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
        gcloud projects create "$PROJECT_ID" --organization="$ORG_ID"
        gcloud beta billing projects link "$PROJECT_ID" \
            --billing-account="$BILLING_ACCOUNT"
    fi

    for api in "${REQUIRED_APIS[@]}"; do
        echo "  · Enabling $api"
        gcloud services enable "$api" --project="$PROJECT_ID" --quiet
    done
done

# ─── Jenkins deploy service account (lives in shared project) ───────────────
echo ""
echo "▸ Creating Jenkins deploy service account"
JENKINS_SA="sa-jenkins-deploy@${STATE_PROJECT}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$JENKINS_SA" --project="$STATE_PROJECT" &>/dev/null; then
    gcloud iam service-accounts create "sa-jenkins-deploy" \
        --project="$STATE_PROJECT" \
        --display-name="Jenkins CI/CD deploy account"
fi

# Give Jenkins SA deploy permissions across all env projects
for env in "${ENVIRONMENTS[@]}"; do
    PROJECT_ID="sync-service-${env}"
    for role in \
        "roles/compute.admin" \
        "roles/artifactregistry.writer" \
        "roles/iam.serviceAccountUser"; do
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:${JENKINS_SA}" \
            --role="$role" \
            --condition=None \
            --quiet > /dev/null
    done
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✅ Bootstrap complete"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Create Atlas MongoDB clusters (one per env) and set up VPC peering"
echo "  2. Reserve DNS for api.sync.acme.com etc."
echo "  3. Run: cd terraform/envs/qa && terraform init && terraform apply"
