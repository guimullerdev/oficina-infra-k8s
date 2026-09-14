# Em conta AWS normal o Terraform cria as duas roles. Em AWS Academy Learner
# Lab, que bloqueia criação de IAM, passe os ARNs de uma role existente
# (LabRole) nas variáveis e o Terraform pula a criação.
locals {
  create_cluster_role = var.existing_cluster_role_arn == ""
  create_node_role    = var.existing_node_role_arn == ""

  cluster_role_arn = local.create_cluster_role ? aws_iam_role.cluster[0].arn : var.existing_cluster_role_arn
  node_role_arn    = local.create_node_role ? aws_iam_role.node[0].arn : var.existing_node_role_arn
}

resource "aws_iam_role" "cluster" {
  count = local.create_cluster_role ? 1 : 0
  name  = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = local.create_cluster_role ? 1 : 0
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  count = local.create_node_role ? 1 : 0
  name  = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# As três policies que todo node group de EKS precisa: registrar o nó no
# cluster, rede de pods (CNI) e pull de imagem do ECR.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.create_node_role ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}
