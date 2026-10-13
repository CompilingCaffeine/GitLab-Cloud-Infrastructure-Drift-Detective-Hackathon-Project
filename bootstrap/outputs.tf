# Copy these into GitLab CI/CD variables (none are secrets).

output "gcp_wif_provider" {
  description = "GCP_WIF_PROVIDER: full resource name of the workload identity provider."
  value       = google_iam_workload_identity_pool_provider.gitlab.name
}

output "gcp_oidc_audience" {
  description = "GCP_OIDC_AUDIENCE: aud claim CI jobs must request in id_tokens."
  value       = local.oidc_audience
}

output "plan_service_account" {
  description = "GCP_PLAN_SA: read-only identity for drift detection and MR plans."
  value       = google_service_account.plan.email
}

output "apply_service_account" {
  description = "GCP_APPLY_SA: identity for reviewed applies on the apply branch."
  value       = google_service_account.apply.email
}

output "web_runtime_service_account" {
  value = google_service_account.web_runtime.email
}

output "internal_runtime_service_account" {
  value = google_service_account.internal_runtime.email
}

output "project_number" {
  value = data.google_project.this.number
}
