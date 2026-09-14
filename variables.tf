variable "aws_region" {
  description = "Região AWS — precisa ser a mesma do RDS (oficina-infra-db) e da Lambda"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "oficina-cluster"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_types" {
  description = "t3.small cobre a app (2 a 5 réplicas do HPA) sem estourar o orçamento de um projeto de curso"
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  description = "Teto de nós. O HPA escala pods até 5 réplicas (ADR 0003); 4 nós dão folga para isso sem autoscaling infinito"
  type        = number
  default     = 4
}

variable "existing_cluster_role_arn" {
  description = "ARN de IAM role já existente para o control plane. Vazio = Terraform cria. Necessário em AWS Academy Learner Lab, que bloqueia criação de roles (use a LabRole)."
  type        = string
  default     = ""
}

variable "existing_node_role_arn" {
  description = "ARN de IAM role já existente para os nós. Vazio = Terraform cria. Idem Learner Lab."
  type        = string
  default     = ""
}

variable "azs_sem_suporte_eks" {
  description = <<-EOT
    Availability zones onde o EKS não cria control plane, e que por isso são
    removidas da lista de subnets do cluster.

    A AWS informa as suportadas na própria mensagem de erro quando a criação
    falha. Em us-east-1 hoje só a `us-east-1e` está de fora; se mudar de
    região, ajuste aqui.
  EOT
  type        = list(string)
  default     = ["us-east-1e"]
}

variable "deploy_principal_arn" {
  description = <<-EOT
    ARN do principal IAM que o pipeline da aplicação usa para falar com o
    cluster. Ganha acesso de admin via EKS access entry.

    Vazio (padrão): usa quem estiver rodando o `terraform apply`, que é o
    caso quando a mesma credencial provisiona a infra e faz o deploy.
    Informe explicitamente se forem principals diferentes.
  EOT
  type        = string
  default     = ""
}
