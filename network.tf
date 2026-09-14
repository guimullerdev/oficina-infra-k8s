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

# ---------------------------------------------------------------------------
# Tags de descoberta de load balancer
# ---------------------------------------------------------------------------
# O cloud-controller-manager do EKS não recebe a lista de subnets: ele
# descobre por tag na hora de criar o load balancer de um Service
# `type: LoadBalancer`. Sem estas duas tags ele não acha subnet nenhuma e o
# Service fica em `<pending>` para sempre, com o evento
# "could not find any suitable subnets for creating the ELB".
#
# Isso importa aqui porque o VPC Link do API Gateway (raiz `api-gateway/`)
# exige um **NLB** — é assim que as rotas `/os/*` chegam na aplicação.
#
# `aws_ec2_tag` em vez de `tags` no recurso: estas subnets são da VPC default,
# criadas pela AWS e lidas como data source. Este repo só acrescenta tags, não
# gerencia o ciclo de vida delas.
resource "aws_ec2_tag" "subnet_cluster" {
  for_each = toset(local.subnet_ids_eks)

  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

# `shared`, não `owned`: a VPC default é compartilhada com o RDS e a Lambda.
# `owned` sinalizaria que o cluster pode dispor da rede como quiser.
resource "aws_ec2_tag" "subnet_internal_elb" {
  for_each = toset(local.subnet_ids_eks)

  resource_id = each.value
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}
