provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "tech-challenge-fase3"
      Repo      = "oficina-infra-k8s"
      Component = "mensageria"
      ManagedBy = "terraform"
    }
  }
}

# Só os tópicos. Fila, DLQ, subscription e IAM pertencem ao repo de cada
# serviço (ADR 0007). Sem KMS e sem topic policy, de propósito.
resource "aws_sns_topic" "os_events" {
  name = "oficina-os-events"
}

resource "aws_sns_topic" "billing_events" {
  name = "oficina-billing-events"
}

resource "aws_sns_topic" "execucao_events" {
  name = "oficina-execucao-events"
}
