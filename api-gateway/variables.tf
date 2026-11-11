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
  description = "Uma stage por ambiente, cada uma invocando o alias de mesmo nome da Lambda (ADR 0002). Hoje só prod."
  type        = list(string)
  default     = ["prod"]
}

variable "discover_nlb" {
  description = "true: descobre o NLB do ingress-nginx pelas tags do cloud provider do EKS e cria as rotas da app (plan falha se 0 ou mais de 1 NLB casar). Ignorado se nlb_arn for informado."
  type        = bool
  default     = false
}

variable "nlb_arn" {
  description = "Override do NLB do ingress-nginx: ARN do load balancer (não do listener); precede discover_nlb. Vazio e discover_nlb = false: só POST /auth/cpf. Descobrir: aws elbv2 describe-load-balancers --query \"LoadBalancers[?Type=='network'].[LoadBalancerArn,DNSName]\" --output text"
  type        = string
  default     = ""
}
