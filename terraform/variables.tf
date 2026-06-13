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
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
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
}

variable "internal_api_key" {
  description = "Internal token shared between the proxy and vLLM. Injected by the proxy as Authorization: Bearer when proxying upstream, satisfying vLLM's --api-key check. Must differ from public_api_key for defense-in-depth to mean anything."
  type        = string
  sensitive   = true
}

variable "system_prompt" {
  description = "System message prepended to every chat. Establishes the chatbot's persona."
  type        = string
  default     = "You are a helpful AI assistant powered by Google's Gemma 4 model and deployed on AWS. Be friendly, clear, and concise. If you don't know something, say so honestly."
}

variable "alert_email" {
  description = "Email address that receives CloudWatch alarm notifications (high latency, high error rate, no healthy targets). The address must confirm the SNS subscription via the AWS confirmation email before notifications begin to flow."
  type        = string
}