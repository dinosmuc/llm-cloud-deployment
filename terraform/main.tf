//TERRAFORM SETTINGS
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.45"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket       = "gemma-inference-tfstate-ds"
    key          = "gemma-inference/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

// AWS PROVIDER
provider "aws" {
  region = var.aws_region
}

//MODULES
module "networking" {
  source       = "./modules/networking"
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  aws_region   = var.aws_region
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}

module "alb" {
  source                = "./modules/alb"
  project_name          = var.project_name
  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  alb_security_group_id = module.networking.alb_security_group_id
}

module "ecs" {
  source                  = "./modules/ecs"
  project_name            = var.project_name
  aws_region              = var.aws_region
  private_subnet_ids      = module.networking.private_subnet_ids
  ecs_security_group_id   = module.networking.ecs_security_group_id
  target_group_arn        = module.alb.target_group_arn
  ecr_repository_url      = module.ecr.repository_url
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  instance_type           = var.instance_type
  min_capacity            = var.min_capacity
  max_capacity            = var.max_capacity
  public_api_key          = var.public_api_key
  internal_api_key        = var.internal_api_key
}

module "frontend" {
  source        = "./modules/frontend"
  project_name  = var.project_name
  alb_dns_name  = module.alb.alb_dns_name
  system_prompt = var.system_prompt
}

module "monitoring" {
  source                  = "./modules/monitoring"
  project_name            = var.project_name
  aws_region              = var.aws_region
  cluster_name            = module.ecs.cluster_name
  service_name            = module.ecs.service_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  alert_email             = var.alert_email
}