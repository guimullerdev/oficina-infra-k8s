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

  depends_on = [aws_iam_role_policy_attachment.node]
}

# Add-ons gerenciados. metrics-server NÃO vem por padrão no EKS (ao contrário
# do GKE) — sem ele o HPA sobe mas fica com métrica <unknown> e nunca escala,
# que é justamente o requisito de escalabilidade da fase (ver ADR 0003).
resource "aws_eks_addon" "this" {
  for_each = toset([
    "vpc-cni",
    "coredns",
    "kube-proxy",
    "metrics-server",
  ])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# Quem cria o cluster recebe admin automaticamente
# (`bootstrap_cluster_creator_admin_permissions`), mas qualquer outro
# principal precisa de access entry explícita. Sem isto, o pipeline da
# aplicação — que autentica como um usuário IAM diferente de quem rodou o
# primeiro apply — recebe "the server has asked for the client to provide
# credentials" e não consegue aplicar manifesto nenhum.
data "aws_caller_identity" "current" {}

locals {
  deploy_principal = var.deploy_principal_arn != "" ? var.deploy_principal_arn : data.aws_caller_identity.current.arn
}

resource "aws_eks_access_entry" "deploy" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.deploy_principal
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "deploy_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.deploy_principal
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.deploy]
}
