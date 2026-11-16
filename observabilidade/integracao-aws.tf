# Vincula a conta AWS ao New Relic e liga a coleta de SQS por polling.
# O New Relic assume a role de iam.tf; a primeira leitura leva ~15 min.
resource "newrelic_cloud_aws_link_account" "oficina" {
  account_id             = var.new_relic_account_id
  arn                    = aws_iam_role.newrelic_integrations.arn
  metric_collection_mode = "PULL"
  name                   = "oficina-aws"

  # A policy precisa existir antes: o link valida o assume-role ao criar.
  depends_on = [aws_iam_role_policy.newrelic_integrations]
}

# Só SQS: é o que as condições de fila precisam, e cada serviço a mais
# aumenta chamadas de API e volume ingerido.
resource "newrelic_cloud_aws_integrations" "oficina" {
  account_id        = var.new_relic_account_id
  linked_account_id = newrelic_cloud_aws_link_account.oficina.id

  sqs {
    aws_regions              = [var.aws_region]
    queue_prefixes           = ["oficina"]
    metrics_polling_interval = 300
    fetch_extended_inventory = true
    fetch_tags               = true
  }
}
