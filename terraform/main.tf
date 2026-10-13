locals {
  labels = {
    app        = "drift-detective"
    managed-by = "terraform"
  }
}

# Public front end. Intentionally reachable by anyone.
# invoker_iam_disabled is used instead of an allUsers binding because the
# organization enforces domain-restricted sharing.
resource "google_cloud_run_v2_service" "web" {
  name                 = "drift-demo-web"
  location             = var.region
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = true
  deletion_protection  = false
  labels               = local.labels

  template {
    service_account = var.web_runtime_service_account

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      env {
        name  = "APP_MODE"
        value = "demo"
      }

      env {
        name  = "INTERNAL_API_URL"
        value = google_cloud_run_v2_service.internal.uri
      }
    }
  }
}

# Internal API. Must require authentication; only the web service may call it.
resource "google_cloud_run_v2_service" "internal" {
  name                 = "drift-demo-internal"
  location             = var.region
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = false
  deletion_protection  = false
  labels               = local.labels

  template {
    service_account = var.internal_runtime_service_account

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      env {
        name  = "APP_MODE"
        value = "internal"
      }
    }
  }
}

# Authoritative for roles/run.invoker: any invoker added outside Terraform
# shows up as drift. (An additive _iam_member would hide it.)
resource "google_cloud_run_v2_service_iam_binding" "internal_invoker" {
  name     = google_cloud_run_v2_service.internal.name
  location = google_cloud_run_v2_service.internal.location
  role     = "roles/run.invoker"
  members  = ["serviceAccount:${var.web_runtime_service_account}"]
}
