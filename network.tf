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

# `aws_subnets` devolve só os ids; precisamos da AZ de cada um para filtrar.
data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  # A VPC default tem subnet em todas as AZs da região, mas o EKS não
  # aceita control plane em algumas delas (em us-east-1, a `us-east-1e`
  # responde UnsupportedAvailabilityZoneException). Filtrar é obrigatório:
  # passar a lista inteira faz a criação do cluster falhar.
  subnet_ids_eks = [
    for s in data.aws_subnet.default : s.id
    if !contains(var.azs_sem_suporte_eks, s.availability_zone)
  ]
}
