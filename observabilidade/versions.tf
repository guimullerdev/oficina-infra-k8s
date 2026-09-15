terraform {
  required_version = ">= 1.9"

  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.43"
    }
  }

  # State próprio, como a raiz `api-gateway/`. Alertas e monitores têm ciclo
  # de vida independente do cluster: mudam quando muda o que a aplicação
  # emite, não quando muda a infraestrutura do EKS.
  backend "s3" {}
}

provider "newrelic" {
  account_id = var.new_relic_account_id
  api_key    = var.new_relic_api_key
  region     = var.new_relic_region
}
