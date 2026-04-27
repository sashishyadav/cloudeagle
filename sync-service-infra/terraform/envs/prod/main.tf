# =============================================================================
# Prod environment — root Terraform
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "sync-service-terraform-state"
    prefix = "prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ─── Inputs ────────────────────────────────────────────────────────────────
variable "project_id" {
  type    = string
  default = "sync-service-prod"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "image_tag" {
  type        = string
  description = "Docker image tag to deploy"
}

variable "domain" {
  type    = string
  default = "api.sync.acme.com"
}

# ─── Modules ───────────────────────────────────────────────────────────────
module "vpc" {
  source      = "../../modules/vpc"
  project_id  = var.project_id
  environment = "prod"
  region      = var.region
  subnet_cidr = "10.0.0.0/20"
}

module "security" {
  source      = "../../modules/security"
  project_id  = var.project_id
  environment = "prod"
}

module "compute" {
  source        = "../../modules/compute"
  project_id    = var.project_id
  environment   = "prod"
  region        = var.region
  subnet_id     = module.vpc.subnet_id
  image_tag     = var.image_tag
  machine_type  = "n2-standard-2"
  min_replicas  = 2
  max_replicas  = 10
  use_preemptible = false

  depends_on = [module.security]
}

module "lb" {
  source             = "../../modules/lb"
  project_id         = var.project_id
  environment        = "prod"
  domain             = var.domain
  mig_instance_group = module.compute.mig_self_link
  health_check_id    = module.compute.health_check_id
  enable_cloud_armor = true    # Prod only
}

# ─── Outputs ───────────────────────────────────────────────────────────────
output "lb_ip" {
  value       = module.lb.lb_ip
  description = "Public IP of the load balancer — point DNS here"
}

output "nat_ip" {
  value       = module.vpc.nat_ip
  description = "Static egress IP — share with 3rd parties for allowlisting"
}

output "runtime_service_account" {
  value = module.compute.service_account
}
