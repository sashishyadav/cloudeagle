# =============================================================================
# VPC Module — sync-service
# -----------------------------------------------------------------------------
# Creates:
#   - Custom-mode VPC (no auto subnets)
#   - One regional subnet with Private Google Access enabled
#   - Cloud Router + Cloud NAT for outbound egress (static IP)
#   - Firewall rules (LB health checks, IAP SSH, implicit deny)
# =============================================================================

variable "project_id"  { type = string }
variable "environment" { type = string }
variable "region"      { type = string }
variable "subnet_cidr" {
  type    = string
  default = "10.0.0.0/20"
}

locals {
  prefix = "sync-service-${var.environment}"
}

# ─── VPC ────────────────────────────────────────────────────────────────────
resource "google_compute_network" "vpc" {
  name                    = "${local.prefix}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "VPC for sync-service ${var.environment}"
}

# ─── Subnet ─────────────────────────────────────────────────────────────────
resource "google_compute_subnetwork" "subnet" {
  name                     = "${local.prefix}-subnet"
  project                  = var.project_id
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true   # Reach GCP APIs without NAT

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ─── Static IP for Cloud NAT ───────────────────────────────────────────────
resource "google_compute_address" "nat_ip" {
  name    = "${local.prefix}-nat-ip"
  project = var.project_id
  region  = var.region
}

# ─── Cloud Router ──────────────────────────────────────────────────────────
resource "google_compute_router" "router" {
  name    = "${local.prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

# ─── Cloud NAT (egress only) ───────────────────────────────────────────────
resource "google_compute_router_nat" "nat" {
  name                               = "${local.prefix}-nat"
  project                            = var.project_id
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat_ip.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─── Firewall: allow GCP LB health checks to :8080 ──────────────────────────
resource "google_compute_firewall" "allow_lb_health" {
  name        = "${local.prefix}-allow-lb-health"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow GCP Load Balancer health check probers"

  direction      = "INGRESS"
  source_ranges  = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags    = ["sync-service"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

# ─── Firewall: SSH only via IAP tunnel ──────────────────────────────────────
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "${local.prefix}-allow-iap-ssh"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow SSH via Identity-Aware Proxy"

  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["sync-service"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ─── Firewall: deny all other inbound ───────────────────────────────────────
resource "google_compute_firewall" "deny_all_other_inbound" {
  name        = "${local.prefix}-deny-all"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Catch-all deny for all other ingress"
  priority    = 65000

  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]

  deny { protocol = "all" }
}

# ─── Outputs ────────────────────────────────────────────────────────────────
output "vpc_id"      { value = google_compute_network.vpc.id }
output "subnet_id"   { value = google_compute_subnetwork.subnet.id }
output "subnet_name" { value = google_compute_subnetwork.subnet.name }
output "nat_ip"      { value = google_compute_address.nat_ip.address }
