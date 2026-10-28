terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # configure.sh fills in the bucket name below (it creates the bucket too)
  backend "s3" {
    bucket = "mahendra-tfstate-977133951325"
    key    = "eks/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "gitops-eks"
      Owner   = "mahendra"
    }
  }
}
