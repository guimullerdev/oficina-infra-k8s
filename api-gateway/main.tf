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

locals {
  lambda_arn = data.terraform_remote_state.auth_lambda.outputs.function_arn

  # Rotas da app só com NLB: informado (nlb_arn) ou descoberto (discover_nlb).
  expor_app = var.nlb_arn != "" || var.discover_nlb

  # Tags que o cloud provider do EKS grava no NLB do Service do ingress-nginx.
  nlb_tags = {
    "kubernetes.io/service-name"            = "ingress-nginx/ingress-nginx-controller"
    "kubernetes.io/cluster/oficina-cluster" = "owned"
  }

  # ARN (VPC Link) e DNS (URIs) do mesmo NLB; null quando expor_app = false.
  nlb_arn      = one(data.aws_lb.ingress[*].arn)
  nlb_dns_name = one(data.aws_lb.ingress[*].dns_name)
}

# arn e tags nunca juntos: o provider aplicaria as tags como filtro extra sobre
# o ARN informado. 0 ou >1 resultados => o plan falha.
data "aws_lb" "ingress" {
  count = local.expor_app ? 1 : 0

  arn  = var.nlb_arn != "" ? var.nlb_arn : null
  tags = var.nlb_arn != "" ? null : local.nlb_tags

  lifecycle {
    postcondition {
      condition     = self.load_balancer_type == "network"
      error_message = "O VPC Link do API Gateway REST exige um Network Load Balancer."
    }
  }
}

# REST API (v1), e não HTTP API (v2), por causa das stage variables: é o que
# permite o recurso invocar o alias da Lambda com o mesmo nome da stage
# (ADR 0002). HTTP API não tem stage variables.
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

  # `stageVariables.alias` faz cada stage invocar o alias da Lambda de mesmo
  # nome (stage prod → alias prod), com uma definição só.
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
# Demais rotas → ingress-nginx no EKS, via VPC Link
# ---------------------------------------------------------------------------

resource "aws_api_gateway_vpc_link" "eks" {
  count = local.expor_app ? 1 : 0

  name        = "${var.api_name}-vpc-link"
  description = "Liga o API Gateway ao NLB do ingress-nginx no EKS, sem passar pela internet"
  target_arns = [local.nlb_arn]

  # NLB novo => VPC Link novo (target_arns força substituição). Criar o novo
  # antes de destruir o antigo deixa a integração e o deployment migrarem
  # sem janela sem VPC Link.
  lifecycle {
    create_before_destroy = true
  }
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

  # O host aqui é o DNS do NLB. O VPC Link decide *por onde* o tráfego passa;
  # a URI é quem diz *para quem* — as duas coisas precisam apontar para o
  # mesmo load balancer, por isso ARN e DNS saem do mesmo data source.
  uri = "http://${local.nlb_dns_name}/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# /auth é um recurso explícito (pai de /auth/cpf), então o {proxy+} da raiz
# não alcança nada abaixo dele. Este proxy leva o resto de /auth/* (register,
# login, refresh...) ao cluster; POST /auth/cpf continua na Lambda porque o
# recurso mais específico vence.
resource "aws_api_gateway_resource" "auth_proxy" {
  count = local.expor_app ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "auth_proxy_any" {
  count = local.expor_app ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.auth_proxy[0].id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "auth_proxy" {
  count = local.expor_app ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.auth_proxy[0].id
  http_method = aws_api_gateway_method.auth_proxy_any[0].http_method

  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.eks[0].id

  # {proxy} só captura o que vem depois de /auth/; o prefixo é recolocado aqui
  # para a app receber o caminho completo (/auth/register), sem a stage.
  uri = "http://${local.nlb_dns_name}/auth/{proxy}"

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
  # continua servindo a definição antiga em silêncio. Os ids das integrações
  # não mudam quando o NLB muda (a integração é atualizada no lugar), por isso
  # uri e connection_id entram aqui. Sem rotas da app a lista termina em
  # "sem-proxy", igual à versão anterior, para não forçar redeploy à toa.
  triggers = {
    redeploy = sha1(jsonencode(concat(
      [
        aws_api_gateway_resource.auth_cpf.id,
        aws_api_gateway_method.auth_cpf_post.id,
        aws_api_gateway_integration.auth_cpf.id,
      ],
      local.expor_app ? concat(
        aws_api_gateway_method.proxy_any[*].id,
        aws_api_gateway_integration.proxy[*].id,
        aws_api_gateway_integration.proxy[*].uri,
        aws_api_gateway_integration.proxy[*].connection_id,
        aws_api_gateway_method.auth_proxy_any[*].id,
        aws_api_gateway_integration.auth_proxy[*].id,
        aws_api_gateway_integration.auth_proxy[*].uri,
        aws_api_gateway_integration.auth_proxy[*].connection_id,
      ) : ["sem-proxy"],
    )))
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
