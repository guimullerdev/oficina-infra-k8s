variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "api_name" {
  type    = string
  default = "oficina-api-gateway"
}

variable "state_bucket" {
  description = "Bucket S3 do backend compartilhado, onde o Gateway lê o state da Lambda"
  type        = string
  default     = "oficina-tfstate-guimullerdev"
}

variable "environments" {
  description = "Um stage do Gateway por ambiente, cada um invocando o alias de mesmo nome da Lambda (ADR 0002)"
  type        = list(string)
  default     = ["homolog", "prod"]
}

variable "nlb_listener_arn" {
  description = <<-EOT
    ARN do listener do Network Load Balancer que expõe o Service da aplicação
    no EKS. Só existe depois que o pipeline do repo da app cria o Service do
    tipo LoadBalancer — por isso é variável, e não um recurso daqui.

    Vazio (padrão): o Gateway sobe só com a rota de autenticação. As rotas
    /os/* não são criadas, em vez de o apply inteiro falhar.
  EOT
  type        = string
  default     = ""
}
