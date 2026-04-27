# =============================================================================
# Compute Module — sync-service
# -----------------------------------------------------------------------------
# Creates:
#   - Instance template (Docker-based via cos-stable or container-optimized)
#   - Regional Managed Instance Group with autohealing
#   - Autoscaler with CPU + LB utilization targets
#   - Dedicated service account with least-privilege IAM
# =============================================================================

variable "project_id"   { type = string }
variable "environment"  { type = string }
variable "region"       { type = string }
variable "subnet_id"    { type = string }
variable "image_tag"    { type = string }
variable "machine_type" {
  type    = string
  default = "e2-medium"
}
variable "use_preemptible" {
  type    = bool
  default = false
}
variable "min_replicas"  {
  type    = number
  default = 2
}
variable "max_replicas"  {
  type    = number
  default = 10
}

locals {
  prefix = "sync-service-${var.environment}"
}

# ─── Service account for runtime ────────────────────────────────────────────
resource "google_service_account" "runtime" {
  account_id   = "sa-${local.prefix}"
  display_name = "Service account for ${local.prefix} runtime"
  project      = var.project_id
}

# Grant SA access to its env's secrets
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.runtime.email}"

  condition {
    title       = "OnlyEnvScopedSecrets"
    description = "Only secrets matching this environment's naming"
    expression  = "resource.name.startsWith('projects/${var.project_id}/secrets/sync-service-') && resource.name.endsWith('-${var.environment}')"
  }
}

# Ops Agent needs write access to Logging + Monitoring
resource "google_project_iam_member" "logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Pull from Artifact Registry
resource "google_project_iam_member" "artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# ─── Instance template ──────────────────────────────────────────────────────
resource "google_compute_instance_template" "template" {
  name_prefix  = "${local.prefix}-tmpl-"
  project      = var.project_id
  region       = var.region
  machine_type = var.machine_type
  tags         = ["sync-service", local.prefix]

  disk {
    source_image = "projects/cos-cloud/global/images/family/cos-stable"
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-balanced"
  }

  network_interface {
    subnetwork = var.subnet_id
    # NO access_config block = no public IP
  }

  service_account {
    email  = google_service_account.runtime.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin      = "TRUE"
    google-logging-enabled = "true"
    google-monitoring-enabled = "true"
    ENVIRONMENT         = var.environment
    IMAGE_TAG           = var.image_tag
    # Container-optimized OS uses this metadata to launch the container
    gce-container-declaration = yamlencode({
      spec = {
        containers = [{
          name  = "sync-service"
          image = "us-central1-docker.pkg.dev/${var.project_id}/sync-service/sync-service:${var.image_tag}"
          env = [
            { name = "SPRING_PROFILES_ACTIVE", value = var.environment },
            { name = "GCP_PROJECT_ID",         value = var.project_id }
          ]
        }]
        restartPolicy = "Always"
      }
    })
  }

  scheduling {
    preemptible        = var.use_preemptible
    automatic_restart  = !var.use_preemptible
    on_host_maintenance = var.use_preemptible ? "TERMINATE" : "MIGRATE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle { create_before_destroy = true }
}

# ─── Health check ──────────────────────────────────────────────────────────
resource "google_compute_health_check" "health" {
  name    = "${local.prefix}-health"
  project = var.project_id

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/actuator/health/liveness"
  }

  log_config { enable = true }
}

# ─── Regional MIG ──────────────────────────────────────────────────────────
resource "google_compute_region_instance_group_manager" "mig" {
  name               = "${local.prefix}-mig"
  project            = var.project_id
  region             = var.region
  base_instance_name = local.prefix

  version {
    instance_template = google_compute_instance_template.template.self_link
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.health.id
    initial_delay_sec = 120   # Allow JVM warmup
  }

  named_port {
    name = "http"
    port = 8080
  }

  update_policy {
    type                    = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action          = "REPLACE"
    max_surge_fixed         = 2
    max_unavailable_fixed   = 0
    replacement_method      = "SUBSTITUTE"
  }
}

# ─── Autoscaler ────────────────────────────────────────────────────────────
resource "google_compute_region_autoscaler" "autoscaler" {
  name    = "${local.prefix}-autoscaler"
  project = var.project_id
  region  = var.region
  target  = google_compute_region_instance_group_manager.mig.id

  autoscaling_policy {
    max_replicas    = var.max_replicas
    min_replicas    = var.min_replicas
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }

    load_balancing_utilization {
      target = 0.8
    }

    scale_in_control {
      max_scaled_in_replicas {
        percent = 25
      }
      time_window_sec = 300
    }
  }
}

# ─── Outputs ───────────────────────────────────────────────────────────────
output "mig_self_link"    { value = google_compute_region_instance_group_manager.mig.instance_group }
output "service_account"  { value = google_service_account.runtime.email }
output "health_check_id"  { value = google_compute_health_check.health.id }
