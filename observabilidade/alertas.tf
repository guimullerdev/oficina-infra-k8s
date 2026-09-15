# ---------------------------------------------------------------------------
# Política e condições de alerta
# ---------------------------------------------------------------------------
# `PER_CONDITION` e não `PER_POLICY`: com uma política só e várias condições,
# agrupar por política faria a segunda falha ser engolida enquanto a primeira
# ainda estivesse aberta. Por condição, cada tipo de problema abre seu próprio
# incidente.
resource "newrelic_alert_policy" "oficina" {
  name                = "Oficina — Tech Challenge Fase 3"
  incident_preference = "PER_CONDITION"
}

# ---------------------------------------------------------------------------
# Falhas no processamento de ordem de serviço
# ---------------------------------------------------------------------------
# O evento vem do filtro de exceções da aplicação, que só marca 5xx como erro:
# 4xx é o cliente errando, e alertar nisso viraria ruído (ver ADR 0004 e
# src/common/filters/http-exception.filter.ts).
resource "newrelic_nrql_alert_condition" "falha_processamento_os" {
  policy_id = newrelic_alert_policy.oficina.id
  name      = "Falha no processamento de OS"
  type      = "static"
  enabled   = true

  # Janela de 5 min agregando por evento. `event_flow` com delay curto porque
  # log chega com atraso pequeno e previsível — não vale usar `cadence`, que
  # esperaria a janela inteira antes de avaliar.
  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 3600
  fill_option                  = "static"
  fill_value                   = 0

  nrql {
    query = "SELECT count(*) FROM Log WHERE event = 'os.processamento.falha'"
  }

  # Uma falha já basta. Não é um alerta sobre volume: qualquer 5xx numa rota
  # de OS significa que um cliente ficou sem resposta, e o correlationId no
  # log leva direto à requisição.
  critical {
    operator              = "above_or_equals"
    threshold             = 1
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}

# ---------------------------------------------------------------------------
# Falhas fora do domínio de OS
# ---------------------------------------------------------------------------
# Mesma ideia, para o resto da API. Limiar mais alto porque aqui entram rotas
# de leitura e utilitárias: uma falha isolada não merece acordar ninguém, um
# punhado em cinco minutos merece.
resource "newrelic_nrql_alert_condition" "falha_requisicao" {
  policy_id = newrelic_alert_policy.oficina.id
  name      = "Falhas de requisição acima do normal"
  type      = "static"
  enabled   = true

  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 3600
  fill_option                  = "static"
  fill_value                   = 0

  nrql {
    query = "SELECT count(*) FROM Log WHERE event = 'requisicao.falha'"
  }

  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}

# ---------------------------------------------------------------------------
# Aplicação sem responder
# ---------------------------------------------------------------------------
# Complementa o Synthetics: o monitor enxerga de fora e pega o caminho todo
# (Gateway, VPC Link, NLB, pod); esta condição enxerga de dentro e pega o caso
# em que a aplicação para de reportar — pods derrubados, CrashLoop, rollout
# que não subiu.
resource "newrelic_nrql_alert_condition" "app_sem_trafego" {
  policy_id = newrelic_alert_policy.oficina.id
  name      = "Aplicação parou de reportar transações"
  type      = "static"
  enabled   = true

  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 3600
  fill_option                  = "static"
  fill_value                   = 0

  nrql {
    query = "SELECT count(*) FROM Transaction WHERE appName LIKE '${var.app_name}%'"
  }

  # `below_or_equals 0` por 10 min: tolera uma janela vazia de madrugada sem
  # abrir incidente, mas não duas seguidas.
  critical {
    operator              = "below_or_equals"
    threshold             = 0
    threshold_duration    = 600
    threshold_occurrences = "all"
  }
}
