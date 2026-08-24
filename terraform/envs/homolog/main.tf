terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.81, < 7.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "eks" {
  source      = "../../modules/eks"
  environment = var.environment
}
