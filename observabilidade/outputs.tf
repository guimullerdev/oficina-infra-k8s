output "policy_id" {
  description = "Id da política de alerta — útil para anexar novas condições sem procurar na interface"
  value       = newrelic_alert_policy.oficina.id
}

output "monitor_guid" {
  description = "GUID do monitor de uptime, para linkar no PDF de entrega"
  value       = newrelic_synthetics_monitor.health_prod.id
}

output "condicoes" {
  description = "Condições criadas, por nome"
  value = [
    newrelic_nrql_alert_condition.falha_processamento_os.name,
    newrelic_nrql_alert_condition.falha_requisicao.name,
    newrelic_nrql_alert_condition.app_sem_trafego.name,
    newrelic_nrql_alert_condition.health_fora_do_ar.name,
  ]
}
