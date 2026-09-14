provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "tech-challenge-fase3"
      Repo      = "oficina-infra-k8s"
      ManagedBy = "terraform"
    }
  }
}

# Mesma VPC default usada por oficina-infra-db e oficina-auth-lambda. Os três
# precisam compartilhar a rede: o RDS é publicly_accessible = false, então só
# quem está dentro da VPC (pods do EKS e a Lambda) alcança o banco.
#
# Por que não uma VPC dedicada: exigiria que este repo fosse aplicado antes do
# infra-db (que já está no ar) e criaria dependência de remote state entre os
# dois. Trade-off aceito para um projeto de curso com uma conta só.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
