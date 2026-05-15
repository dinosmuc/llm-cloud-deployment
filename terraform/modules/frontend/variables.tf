variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name for API requests"
  type        = string
}

variable "system_prompt" {
  description = "System message injected into the served app.js via templatefile()"
  type        = string
}