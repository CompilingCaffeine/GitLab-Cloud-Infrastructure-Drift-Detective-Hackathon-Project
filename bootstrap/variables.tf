variable "project_id" {
  description = "Google Cloud project that hosts the demo environment."
  type        = string
  default     = "drift-detective-2026"
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "gitlab_project_path" {
  description = "Full path of the only GitLab project allowed to exchange CI OIDC tokens."
  type        = string
  default     = "gitlab-ai-hackathon/transcend-october-2026/33443675/showcase"
}

variable "apply_branch" {
  description = "Only pipelines on this branch may impersonate the apply service account."
  type        = string
  default     = "main"
}
