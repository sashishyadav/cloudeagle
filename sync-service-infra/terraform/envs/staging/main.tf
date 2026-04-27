# =============================================================================
# Staging environment — root Terraform
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
    prefix = "staging"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type    = string
  default = "sync-service-staging"
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
  default = "staging.sync.acme.com"
}

module "vpc" {
  source      = "../../modules/vpc"
  project_id  = var.project_id
  environment = "staging"
  region      = var.region
  subnet_cidr = "10.2.0.0/20"
}

module "security" {
  source      = "../../modules/security"
  project_id  = var.project_id
  environment = "staging"
}

module "compute" {
  source        = "../../modules/compute"
  project_id    = var.project_id
  environment   = "staging"
  region        = var.region
  subnet_id     = module.vpc.subnet_id
  image_tag     = var.image_tag
  machine_type  = "e2-medium"
  min_replicas  = 1
  max_replicas  = 4

  depends_on = [module.security]
}

module "lb" {
  source             = "../../modules/lb"
  project_id         = var.project_id
  environment        = "staging"
  domain             = var.domain
  mig_instance_group = module.compute.mig_self_link
  health_check_id    = module.compute.health_check_id
  enable_cloud_armor = false
}

output "lb_ip" { value = module.lb.lb_ip }
output "nat_ip" { value = module.vpc.nat_ip }
