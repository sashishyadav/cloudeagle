# =============================================================================
# Security Module — sync-service
# -----------------------------------------------------------------------------
# Manages Secret Manager secrets for runtime config.
# Does NOT create the secret VALUES — those are set manually by ops or via
# `gcloud secrets versions add` as part of the provisioning runbook.
# Terraform only manages the secret container + IAM.
# =============================================================================

variable "project_id"  { type = string }
variable "environment" { type = string }

locals {
  secrets = [
    "mongo-uri",
    "api-key",
    "jwt-signing-key",
  ]
}

# ─── Secrets ───────────────────────────────────────────────────────────────
resource "google_secret_manager_secret" "secrets" {
  for_each  = toset(local.secrets)
  secret_id = "sync-service-${each.value}-${var.environment}"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    service     = "sync-service"
    managed-by  = "terraform"
  }
}

# ─── Placeholder initial versions ──────────────────────────────────────────
# Terraform creates a placeholder secret version so downstream resources don't
# fail on a missing version. OPS MUST REPLACE these with real values.
resource "google_secret_manager_secret_version" "placeholders" {
  for_each    = google_secret_manager_secret.secrets
  secret      = each.value.id
  secret_data = "PLACEHOLDER_REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# ─── Outputs ───────────────────────────────────────────────────────────────
output "secret_ids" {
  value = { for k, v in google_secret_manager_secret.secrets : k => v.id }
}
