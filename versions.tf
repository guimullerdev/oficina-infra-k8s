terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Mesmo bucket/tabela dos outros repos de infra, key própria (ver ADR 0001).
  backend "s3" {}
}
