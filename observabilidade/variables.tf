variable "new_relic_account_id" {
  description = "Id da conta New Relic — o mesmo do dashboard versionado em TECH-CHALLENGE-FASE-ONE/docs/observabilidade/"
  type        = number
  default     = 8510401
}

variable "new_relic_api_key" {
  description = <<-EOT
    **User key** (`NRAK-...`), não a license key.

    São chaves diferentes: a license key (`NEW_RELIC_LICENSE_KEY`) só permite
    que os agentes *enviem* dados, e é a que está no Secret do Kubernetes.
    Criar alerta e monitor exige uma User key, que é a única aceita pela
    NerdGraph para escrita.

    Vem do secret `NEW_RELIC_API_KEY` do repositório, via `TF_VAR_*`.
  EOT
  type        = string
  sensitive   = true

  # Secret inexistente no GitHub vira TF_VAR_* com string vazia, e o
  # Terraform aceita isso como valor legítimo — o apply passaria e criaria
  # nada, ou falharia com erro de autenticação obscuro. Mesma armadilha que
  # derrubou a autenticação em produção no merge do PR #4 da Lambda.
  validation {
    condition     = trimspace(var.new_relic_api_key) != ""
    error_message = "new_relic_api_key está vazia. Confira o secret NEW_RELIC_API_KEY no repositório."
  }

  validation {
    condition     = startswith(var.new_relic_api_key, "NRAK-")
    error_message = "new_relic_api_key não começa com NRAK-. Provavelmente é a license key (ingest), que não cria recursos."
  }
}

variable "new_relic_region" {
  description = "Região da conta New Relic: US ou EU. A conta 8510401 responde em one.newrelic.com, ou seja, US."
  type        = string
  default     = "US"

  validation {
    condition     = contains(["US", "EU"], var.new_relic_region)
    error_message = "new_relic_region deve ser US ou EU."
  }
}

variable "email_notificacao" {
  description = "Endereço que recebe os alertas. Sem ele a condição dispara e ninguém fica sabendo."
  type        = string
}

variable "url_health_check" {
  description = "URL que o monitor de uptime consulta — o /health no stage de produção do API Gateway"
  type        = string
  default     = "https://7eu2kz40xj.execute-api.us-east-1.amazonaws.com/prod/health"
}

variable "app_name" {
  description = "Nome da aplicação no APM, usado para filtrar as condições de alerta"
  type        = string
  default     = "oficina-api"
}
