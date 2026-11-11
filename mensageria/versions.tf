terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State próprio: os tópicos são consumidos por vários repos e não devem
  # disputar lock com o cluster nem com o Gateway.
  backend "s3" {}
}
