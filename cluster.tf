resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = local.cluster_role_arn

  # Explícito, e não o default do provider (`true`), por dois motivos: os
  # add-ons são declarados abaixo como `aws_eks_addon` gerenciados, então
  # não queremos as cópias self-managed que o bootstrap instalaria; e o
  # campo força recriação do cluster, de modo que deixá-lo implícito faz
  # qualquer `plan` futuro querer destruir e recriar o control plane.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids = local.subnet_ids_eks
    # Endpoint público: o pipeline do repo da app roda em runner hospedado do
    # GitHub (fora da VPC) e precisa alcançar a API do cluster pra aplicar os
    # manifestos. O acesso continua autenticado por IAM.
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Habilita o provedor OIDC, que é o que permite dar permissão a um
  # ServiceAccount sem colocar credencial de AWS dentro do pod.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = local.node_role_arn
  subnet_ids      = local.subnet_ids_eks

  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # Os add-ons de rede vêm ANTES dos nós. Com
  # `bootstrap_self_managed_addons = false` o cluster nasce sem CNI nem
  # kube-proxy; um nó que sobe assim nunca fica Ready e o node group termina
  # em CREATE_FAILED (NodeCreationFailure).
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.rede,
  ]
}

# Add-ons gerenciados, em dois grupos por causa da ordem de criação.
#
# `rede` (vpc-cni, kube-proxy) são DaemonSets: instalam sem nó nenhum e
# precisam existir para o nó ficar Ready.
resource "aws_eks_addon" "rede" {
  for_each = toset([
    "vpc-cni",
    "kube-proxy",
  ])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# `workloads` (coredns, metrics-server) são Deployments: sem nó para agendar
# os pods o add-on fica DEGRADED e o apply estoura o timeout, então entram
# depois do node group. metrics-server NÃO vem por padrão no EKS (ao contrário
# do GKE) — sem ele o HPA sobe mas fica com métrica <unknown> e nunca escala,
# que é justamente o requisito de escalabilidade da fase (ver ADR 0003).
resource "aws_eks_addon" "workloads" {
  for_each = toset([
    "coredns",
    "metrics-server",
  ])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# Quem cria o cluster recebe admin automaticamente
# (`bootstrap_cluster_creator_admin_permissions`): o EKS cria a access entry
# desse principal sozinho, e declarar outra para o mesmo ARN falha com 409
# (ResourceInUseException). Por isso a entry explícita só existe quando o
# principal do pipeline da aplicação é DIFERENTE de quem roda o apply. Sem
# ela, esse outro principal recebe "the server has asked for the client to
# provide credentials" e não consegue aplicar manifesto nenhum.
data "aws_caller_identity" "current" {}

locals {
  deploy_principal_extra = (
    var.deploy_principal_arn != "" &&
    var.deploy_principal_arn != data.aws_caller_identity.current.arn
  )
}

resource "aws_eks_access_entry" "deploy" {
  count = local.deploy_principal_extra ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.deploy_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "deploy_admin" {
  count = local.deploy_principal_extra ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.deploy_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.deploy]
}
