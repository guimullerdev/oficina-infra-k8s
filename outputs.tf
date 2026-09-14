# Estes outputs são o contrato deste repo com o pipeline do repo da app, que
# é quem aplica Deployment/Service/HPA/ConfigMap/Secret (ver ADR 0001).
# Este repo não aplica manifesto de aplicação nenhum.

output "cluster_name" {
  description = "Usado pelo pipeline da app em `aws eks update-kubeconfig --name`"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  description = "CA do cluster, para montar kubeconfig sem passar pelo update-kubeconfig"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "Issuer OIDC — base para dar permissão AWS a um ServiceAccount (IRSA)"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "vpc_id" {
  description = "VPC onde o cluster roda — a mesma do RDS e da Lambda, por isso os pods alcançam o banco"
  value       = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "Subnets do cluster — o API Gateway (Fase 6) usa para o VPC Link"
  value       = data.aws_subnets.default.ids
}

output "node_security_group_id" {
  description = "SG gerenciado pelo EKS para os nós"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
