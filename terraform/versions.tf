terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.5"
    }
  }

  # GitLab-managed state. Address, lock and credentials are supplied at init time
  # (by the OpenTofu CI component in pipelines, or -backend-config locally).
  backend "http" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
