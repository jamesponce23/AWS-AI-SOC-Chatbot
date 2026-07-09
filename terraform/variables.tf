variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the OIDC deploy role"
  type        = string
  default     = "jamesponce23/AWS-AI-SOC-Chatbot"
}

variable "github_deploy_ref" {
  description = "Git ref the OIDC deploy role is scoped to (only this branch can deploy)"
  type        = string
  default     = "refs/heads/main"
}
