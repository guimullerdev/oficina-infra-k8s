output "api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "invoke_urls" {
  description = "URL base de cada stage (hoje só prod). Com rotas_da_app_expostas = false, só POST /auth/cpf responde nela."
  value       = { for env, stage in aws_api_gateway_stage.environment : env => stage.invoke_url }
}

output "auth_endpoints" {
  description = "POST /auth/cpf (Lambda) de cada stage; existe com ou sem NLB"
  value       = { for env, stage in aws_api_gateway_stage.environment : env => "${stage.invoke_url}/auth/cpf" }
}

output "rotas_da_app_expostas" {
  description = "true com nlb_arn ou discover_nlb (/{proxy+} e /auth/{proxy+} via VPC Link); false = só POST /auth/cpf"
  value       = local.expor_app
}

output "nlb_dns_name" {
  description = "DNS do NLB usado nas integrações (null sem rotas da app)"
  value       = local.nlb_dns_name
}
