output "os_events_topic_arn" {
  description = "ARN do tópico oficina-os-events"
  value       = aws_sns_topic.os_events.arn
}

output "billing_events_topic_arn" {
  description = "ARN do tópico oficina-billing-events"
  value       = aws_sns_topic.billing_events.arn
}

output "execucao_events_topic_arn" {
  description = "ARN do tópico oficina-execucao-events"
  value       = aws_sns_topic.execucao_events.arn
}
