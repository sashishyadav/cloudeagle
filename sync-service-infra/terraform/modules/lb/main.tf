# =============================================================================
# Load Balancer Module — sync-service
# -----------------------------------------------------------------------------
# Global External HTTPS Load Balancer + Cloud Armor security policy.
#
# Components:
#   - Backend service pointing to the MIG
#   - URL map (path → backend)
#   - Target HTTPS proxy with Google-managed TLS cert
#   - Global forwarding rule (public IP)
#   - HTTP → HTTPS redirect
#   - Cloud Armor policy (prod only)
# =============================================================================

variable "project_id"              { type = string }
variable "environment"             { type = string }
variable "domain"                  { type = string }
variable "mig_instance_group"      { type = string }
variable "health_check_id"         { type = string }
variable "enable_cloud_armor"      {
  type    = bool
  default = false
}

locals {
  prefix = "sync-service-${var.environment}"
}

# ─── Public IP ─────────────────────────────────────────────────────────────
resource "google_compute_global_address" "lb_ip" {
  name    = "${local.prefix}-lb-ip"
  project = var.project_id
}

# ─── Cloud Armor policy ─────────────────────────────────────────────────────
resource "google_compute_security_policy" "armor" {
  count   = var.enable_cloud_armor ? 1 : 0
  name    = "${local.prefix}-armor"
  project = var.project_id

  # Default rule — allow all (subject to below)
  rule {
    action   = "allow"
    priority = 2147483647
    description = "Default allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
  }

  # Rate limit: 1000 req/min per IP
  rule {
    action   = "throttle"
    priority = 1000
    description = "Per-IP rate limit"

    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = 1000
        interval_sec = 60
      }
    }
  }

  # Block SQL injection attempts
  rule {
    action   = "deny(403)"
    priority = 100
    description = "Block SQL injection"
    match {
      expr { expression = "evaluatePreconfiguredExpr('sqli-v33-stable')" }
    }
  }

  # Block XSS attempts
  rule {
    action   = "deny(403)"
    priority = 110
    description = "Block XSS"
    match {
      expr { expression = "evaluatePreconfiguredExpr('xss-v33-stable')" }
    }
  }
}

# ─── Backend service ───────────────────────────────────────────────────────
resource "google_compute_backend_service" "backend" {
  name          = "${local.prefix}-backend"
  project       = var.project_id
  protocol      = "HTTP"
  port_name     = "http"
  timeout_sec   = 30
  health_checks = [var.health_check_id]

  security_policy = var.enable_cloud_armor ? google_compute_security_policy.armor[0].id : null

  backend {
    group           = var.mig_instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }

  connection_draining_timeout_sec = 30

  log_config {
    enable      = true
    sample_rate = var.environment == "prod" ? 0.1 : 1.0
  }
}

# ─── URL map ───────────────────────────────────────────────────────────────
resource "google_compute_url_map" "default" {
  name            = "${local.prefix}-urlmap"
  project         = var.project_id
  default_service = google_compute_backend_service.backend.id
}

# ─── Managed TLS cert ──────────────────────────────────────────────────────
resource "google_compute_managed_ssl_certificate" "cert" {
  name    = "${local.prefix}-cert"
  project = var.project_id

  managed {
    domains = [var.domain]
  }

  lifecycle { create_before_destroy = true }
}

# ─── HTTPS proxy + forwarding rule ─────────────────────────────────────────
resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "${local.prefix}-https-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cert.id]
  quic_override    = "ENABLE"
}

resource "google_compute_global_forwarding_rule" "https" {
  name       = "${local.prefix}-https-fr"
  project    = var.project_id
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "443"
  target     = google_compute_target_https_proxy.https_proxy.id
}

# ─── HTTP → HTTPS redirect ─────────────────────────────────────────────────
resource "google_compute_url_map" "http_redirect" {
  name    = "${local.prefix}-http-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "${local.prefix}-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "${local.prefix}-http-fr"
  project    = var.project_id
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "80"
  target     = google_compute_target_http_proxy.http_proxy.id
}

# ─── Outputs ───────────────────────────────────────────────────────────────
output "lb_ip"              { value = google_compute_global_address.lb_ip.address }
output "backend_service_id" { value = google_compute_backend_service.backend.id }
