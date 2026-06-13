variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "ecs_security_group_id" {
  description = "Security group ID for ECS tasks"
  type        = string
}

variable "target_group_arn" {
  description = "ALB target group ARN"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix used as a CloudWatch dimension on the scale-from-zero and scale-in alarms"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target-group ARN suffix used to build the resource_label for the ALBRequestCountPerTarget predefined metric"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks"
  type        = number
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks"
  type        = number
}

variable "public_api_key" {
  description = "User-facing API key. Clients send it in the x-api-key header; the proxy validates it before proxying to vLLM."
  type        = string
  sensitive   = true
}

variable "internal_api_key" {
  description = "Internal token shared between the proxy and vLLM. Injected by the proxy as Authorization: Bearer when proxying upstream, satisfying vLLM's --api-key check."
  type        = string
  sensitive   = true
}