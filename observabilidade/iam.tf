# Role que o New Relic assume para consultar a AWS por API polling.
#
# Existe porque a integração não tem acesso à conta por conta própria: ela
# faz sts:AssumeRole nesta role e lê métricas do CloudWatch e metadados do
# SQS. A confiança é restrita à conta AWS do New Relic (754728514883) e ao
# ExternalId, que é o id da conta New Relic — só quem conhece os dois assume.
#
# Vive nesta raiz, e não na do cluster, então sobrevive ao teardown do EKS.
# Custo zero: IAM não é cobrado.
resource "aws_iam_role" "newrelic_integrations" {
  name        = "NewRelicIntegrations"
  description = "Assumida pelo New Relic para ler métricas do SQS (API polling)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::754728514883:root" }
      Condition = {
        StringEquals = {
          "sts:ExternalId" = tostring(var.new_relic_account_id)
        }
      }
    }]
  })
}

# Somente leitura, e só o que o polling do SQS usa.
resource "aws_iam_role_policy" "newrelic_integrations" {
  name = "NewRelicSqsReadOnly"
  role = aws_iam_role.newrelic_integrations.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ListQueues",
        "sqs:GetQueueAttributes",
        "sqs:ListQueueTags",
        "tag:GetResources",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
      ]
      Resource = "*"
    }]
  })
}
