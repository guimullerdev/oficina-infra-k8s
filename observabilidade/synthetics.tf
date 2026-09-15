# ---------------------------------------------------------------------------
# Monitoramento externo de uptime
# ---------------------------------------------------------------------------
# Checa de fora da AWS, o que é o ponto: o agente dentro do pod só sabe dizer
# que a aplicação está viva para quem já chegou nela. O Synthetics atravessa o
# caminho inteiro — API Gateway, VPC Link, NLB, pod — e é o único que percebe
# uma quebra nas camadas de rede entre eles.
resource "newrelic_synthetics_monitor" "health_prod" {
  account_id = var.new_relic_account_id
  name       = "Oficina — health (prod)"
  type       = "SIMPLE"
  status     = "ENABLED"
  uri        = var.url_health_check
  period     = "EVERY_5_MINUTES"

  # Duas regiões, não uma: com um local só, uma instabilidade de rede do
  # próprio ponto de checagem vira alarme falso.
  locations_public = ["AWS_US_EAST_1", "AWS_SA_EAST_1"]

  # Não basta responder 200 — o corpo precisa ser o do healthcheck. Uma página
  # de erro do Gateway com 200 passaria na checagem de status.
  validation_string         = "\"status\":\"ok\""
  verify_ssl                = true
  treat_redirect_as_failure = true
}

# Alerta do monitor, ligado à mesma política das falhas de aplicação para o
# time ter um lugar só onde olhar.
resource "newrelic_nrql_alert_condition" "health_fora_do_ar" {
  policy_id = newrelic_alert_policy.oficina.id
  name      = "Health check externo falhando"
  type      = "static"
  enabled   = true

  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 3600

  nrql {
    query = "SELECT count(*) FROM SyntheticCheck WHERE monitorName = '${newrelic_synthetics_monitor.health_prod.name}' AND result = 'FAILED'"
  }

  # Duas falhas seguidas (o monitor roda a cada 5 min, de dois locais): uma
  # falha isolada costuma ser a rede do ponto de checagem, não a aplicação.
  critical {
    operator              = "above_or_equals"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}
