data "google_project" "this" {}

locals {
  oidc_audience = "https://gitlab.com/${var.gitlab_project_path}"
  pool_name     = google_iam_workload_identity_pool.gitlab.name
}

# --- GitLab CI -> Google Cloud federation (no long-lived keys) ---

resource "google_iam_workload_identity_pool" "gitlab" {
  workload_identity_pool_id = "gitlab-ci"
  display_name              = "GitLab CI"
  description               = "OIDC tokens from GitLab CI jobs in the drift detective project"
}

resource "google_iam_workload_identity_pool_provider" "gitlab" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = "gitlab-com"
  display_name                       = "gitlab.com"

  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.project_path" = "assertion.project_path"
    # Empty for tags and MR refs, so only real branch pipelines match a branch principal.
    "attribute.branch" = "assertion.ref_type == 'branch' ? assertion.ref : ''"
  }

  # Reject tokens from every other GitLab project before any IAM check runs.
  attribute_condition = "assertion.project_path == '${var.gitlab_project_path}'"

  oidc {
    issuer_uri        = "https://gitlab.com"
    allowed_audiences = [local.oidc_audience]
  }
}

# --- Identities used by CI ---

# Read-only: drift detection and MR plans. Any pipeline in the project may use it.
resource "google_service_account" "plan" {
  account_id   = "drift-plan"
  display_name = "Drift detective: plan (read-only)"
}

resource "google_project_iam_member" "plan_run_viewer" {
  project = var.project_id
  role    = "roles/run.viewer"
  member  = google_service_account.plan.member
}

resource "google_service_account_iam_member" "plan_wif" {
  service_account_id = google_service_account.plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.project_path/${var.gitlab_project_path}"
}

# Write: applies reviewed plans. Only pipelines on the apply branch may use it.
resource "google_service_account" "apply" {
  account_id   = "drift-apply"
  display_name = "Drift detective: apply (main branch only)"
}

resource "google_project_iam_member" "apply_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = google_service_account.apply.member
}

resource "google_service_account_iam_member" "apply_wif" {
  service_account_id = google_service_account.apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.branch/${var.apply_branch}"
}

# --- Runtime identities for the demo services (no project roles) ---

resource "google_service_account" "web_runtime" {
  account_id   = "drift-demo-web"
  display_name = "Drift demo: public web service runtime"
}

resource "google_service_account" "internal_runtime" {
  account_id   = "drift-demo-internal"
  display_name = "Drift demo: internal API runtime"
}

# Deploying a service that runs as these accounts requires actAs on them.
resource "google_service_account_iam_member" "apply_act_as" {
  for_each = {
    web      = google_service_account.web_runtime.name
    internal = google_service_account.internal_runtime.name
  }

  service_account_id = each.value
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.apply.member
}
