# ---------------------------------------------------------------------------
# Para onde o alerta vai
# ---------------------------------------------------------------------------
# Uma condição que dispara sem destino não alerta ninguém — só fica registrada
# na interface. O caminho no New Relic é destination → channel → workflow.
resource "newrelic_notification_destination" "email" {
  account_id = var.new_relic_account_id
  name       = "Oficina — e-mail do time"
  type       = "EMAIL"

  property {
    key   = "email"
    value = var.email_notificacao
  }
}

resource "newrelic_notification_channel" "email" {
  account_id     = var.new_relic_account_id
  name           = "Oficina — incidentes por e-mail"
  type           = "EMAIL"
  destination_id = newrelic_notification_destination.email.id
  product        = "IINT"

  property {
    key   = "subject"
    value = "[Oficina] {{ issueTitle }}"
  }
}

resource "newrelic_workflow" "oficina" {
  account_id            = var.new_relic_account_id
  name                  = "Oficina — notificar incidentes"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "incidentes da política da oficina"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.oficina.id]
    }
  }

  destination {
    channel_id = newrelic_notification_channel.email.id
  }
}
