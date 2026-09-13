variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "gemma-inference"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. The four subnets are carved out of it with cidrsubnet(), so overriding this actually moves them."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    // The subnets are derived as cidrsubnet(vpc_cidr, 8, n), which needs 8 spare bits
    // and a prefix short enough that the resulting /28-or-wider blocks are valid in AWS.
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix of /20 or shorter, so the four derived subnets fit inside it."
  }
}

variable "instance_type" {
  description = "EC2 instance type for ECS GPU tasks (Gemma 4 attention requires L4-class, not T4)"
  type        = string
  default     = "g6.xlarge"
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks (0 = scale to zero)"
  type        = number
  default     = 0
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks"
  type        = number
  default     = 3
}

variable "public_api_key" {
  description = "User-facing API key. Clients send it in the x-api-key header; the proxy validates it before proxying to vLLM."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.public_api_key) >= 20
    error_message = "public_api_key must be at least 20 characters. Generate one with: openssl rand -base64 24"
  }

  validation {
    // terraform.tfvars.example ships a placeholder. Applying it unedited would put a
    // published, guessable key in front of a GPU endpoint, so refuse to deploy it.
    condition     = !can(regex("(?i)key-here|any-random-string|changeme|example|your-", var.public_api_key))
    error_message = "public_api_key still looks like the placeholder from terraform.tfvars.example. Replace it with a real secret."
  }
}

variable "internal_api_key" {
  description = "Internal token shared between the proxy and vLLM. Injected by the proxy as Authorization: Bearer when proxying upstream, satisfying vLLM's --api-key check. Must differ from public_api_key for defense-in-depth to mean anything."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.internal_api_key) >= 20
    error_message = "internal_api_key must be at least 20 characters. Generate one with: openssl rand -base64 24"
  }

  validation {
    condition     = !can(regex("(?i)key-here|any-random-string|changeme|example|your-", var.internal_api_key))
    error_message = "internal_api_key still looks like the placeholder from terraform.tfvars.example. Replace it with a real secret."
  }

  validation {
    // The description above has always said the two keys must differ; this enforces it.
    // Cross-variable references in validation blocks need Terraform >= 1.9, which the
    // root already requires (>= 1.10.0 for S3 native locking).
    condition     = var.internal_api_key != var.public_api_key
    error_message = "internal_api_key must differ from public_api_key. Reusing one key collapses the two-tier auth into a single shared secret."
  }
}

variable "system_prompt" {
  description = "System message prepended to every chat. Establishes the chatbot's persona."
  type        = string
  default     = "You are a helpful AI assistant. Be friendly, clear, and concise. If you don't know something, say so honestly."
}

variable "alert_email" {
  description = "Email address that receives CloudWatch alarm notifications (high latency, high error rate, no healthy targets). The address must confirm the SNS subscription via the AWS confirmation email before notifications begin to flow. Empty disables email delivery only: the alarms and the SNS topic are still created, so a subscription can be added later without touching the stack."
  type        = string
  default     = ""

  validation {
    // Empty is the deliberate opt-out, so it skips the format check. Anything else
    // still has to look like an address.
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address, or empty to disable email notifications; SNS silently never delivers to a malformed one."
  }
}
