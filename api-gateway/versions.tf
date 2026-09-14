terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State próprio, separado do cluster: o Gateway depende da Lambda (outro
  # repo) e do Service da app, que têm ciclo de vida diferente do EKS.
  backend "s3" {}
}
