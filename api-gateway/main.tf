provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "tech-challenge-fase3"
      Repo      = "oficina-infra-k8s"
      Component = "api-gateway"
      ManagedBy = "terraform"
    }
  }
}

# A Lambda é provisionada por oficina-auth-lambda; aqui só lemos o ARN dela.
# Por isso este módulo é aplicado depois daquele repo.
data "terraform_remote_state" "auth_lambda" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "auth-lambda/terraform.tfstate"
    region = var.aws_region
  }
}

# Subnets do cluster, para o VPC Link alcançar o Service da app.
data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "infra-k8s/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  lambda_arn = data.terraform_remote_state.auth_lambda.outputs.function_arn
  subnet_ids = data.terraform_remote_state.cluster.outputs.subnet_ids

  # Só cria as rotas para o cluster quando o NLB do Service já existe.
  expor_app = var.nlb_listener_arn != ""
}

# REST API (v1), e não HTTP API (v2), por causa das stage variables: é o que
# permite um mesmo recurso invocar um alias diferente da Lambda por stage
# (homolog/prod, ADR 0002). HTTP API não tem stage variables.
resource "aws_api_gateway_rest_api" "this" {
  name        = var.api_name
  description = "Porta de entrada da oficina: autenticação por CPF (Lambda) e APIs da aplicação (EKS)"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ---------------------------------------------------------------------------
# Autenticação por CPF → Lambda
# ---------------------------------------------------------------------------

resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "auth"
}

resource "aws_api_gateway_resource" "auth_cpf" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "cpf"
}

# Sem autorização: é justamente onde o token é obtido — exigir token aqui
# seria circular.
resource "aws_api_gateway_method" "auth_cpf_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.auth_cpf.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "auth_cpf" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.auth_cpf.id
  http_method = aws_api_gateway_method.auth_cpf_post.http_method

  # AWS_PROXY sempre usa POST para invocar a Lambda, independente do método
  # que o cliente chamou — não é engano.
  integration_http_method = "POST"
  type                    = "AWS_PROXY"

  # `stageVariables.alias` é o que faz o stage /homolog invocar o alias
  # homolog e o /prod invocar o prod, com uma definição só.
  uri = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${local.lambda_arn}:$${stageVariables.alias}/invocations"
}

resource "aws_lambda_permission" "api_gateway" {
  for_each = toset(var.environments)

  statement_id  = "AllowAPIGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = local.lambda_arn
  qualifier     = each.key
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/auth/cpf"
}

# ---------------------------------------------------------------------------
# Demais rotas → Service da aplicação no EKS, via VPC Link
# ---------------------------------------------------------------------------

resource "aws_api_gateway_vpc_link" "eks" {
  count = local.expor_app ? 1 : 0

  name        = "${var.api_name}-vpc-link"
  description = "Liga o API Gateway ao NLB do Service da aplicação, sem passar pela internet"
  target_arns = [var.nlb_listener_arn]
}

resource "aws_api_gateway_resource" "proxy" {
  count = local.expor_app ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

# A autorização real é o JWT, validado pelo JwtAuthGuard da aplicação — o
# Gateway roteia, não autentica. Centralizar a validação na app evita ter a
# regra de autorização duplicada em dois lugares que podem divergir.
resource "aws_api_gateway_method" "proxy_any" {
  count = local.expor_app ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.proxy[0].id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "proxy" {
  count = local.expor_app ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.proxy[0].id
  http_method = aws_api_gateway_method.proxy_any[0].http_method

  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.eks[0].id
  uri                     = "http://placeholder/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# ---------------------------------------------------------------------------
# Deployment e stages
# ---------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Sem isso, mudar um método/integração não gera deployment novo e a API
  # continua servindo a definição antiga em silêncio.
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.auth_cpf.id,
      aws_api_gateway_method.auth_cpf_post.id,
      aws_api_gateway_integration.auth_cpf.id,
      local.expor_app ? aws_api_gateway_integration.proxy[0].id : "sem-proxy",
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "environment" {
  for_each = toset(var.environments)

  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = each.key

  variables = {
    alias = each.key
  }
}
