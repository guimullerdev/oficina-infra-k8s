output "api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "invoke_urls" {
  description = "URL base de cada ambiente — é o endereço público da oficina, o único que o cliente precisa conhecer"
  value       = { for env, stage in aws_api_gateway_stage.environment : env => stage.invoke_url }
}

output "auth_endpoints" {
  description = "Endpoint de autenticação por CPF por ambiente"
  value       = { for env, stage in aws_api_gateway_stage.environment : env => "${stage.invoke_url}/auth/cpf" }
}

output "rotas_da_app_expostas" {
  description = "false enquanto `nlb_listener_arn` não for informado — nesse caso só a autenticação está roteada"
  value       = local.expor_app
}
