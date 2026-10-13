variable "project_id" {
  description = "Google Cloud project that hosts the demo environment."
  type        = string
  default     = "drift-detective-2026"
}

variable "region" {
  description = "Region for the Cloud Run services."
  type        = string
  default     = "us-central1"
}

variable "image" {
  description = "Container image for both demo services."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello:latest"
}

variable "web_runtime_service_account" {
  description = "Runtime identity of the public web service (created by bootstrap/)."
  type        = string
  default     = "drift-demo-web@drift-detective-2026.iam.gserviceaccount.com"
}

variable "internal_runtime_service_account" {
  description = "Runtime identity of the internal API (created by bootstrap/)."
  type        = string
  default     = "drift-demo-internal@drift-detective-2026.iam.gserviceaccount.com"
}
