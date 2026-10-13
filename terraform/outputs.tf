output "web_url" {
  description = "Public URL of the demo web service."
  value       = google_cloud_run_v2_service.web.uri
}

output "internal_url" {
  description = "URL of the internal API (requires authentication)."
  value       = google_cloud_run_v2_service.internal.uri
}
