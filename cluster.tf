resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = local.cluster_role_arn

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
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
  subnet_ids      = data.aws_subnets.default.ids

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
