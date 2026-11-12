# Testes funcionais da exposicao da aplicacao via NLB do ingress.
#
# O que prova:
#   (a) sem NLB (defaults): nenhum VPC Link, nenhum {proxy+} nem /auth/{proxy+},
#       e uma unica stage "prod";
#   (b) discover_nlb = true: VPC Link e rotas {proxy+} e /auth/{proxy+} criados;
#   (c) nlb_arn informado: mesmo resultado de (b), e o data.aws_lb.ingress usa o ARN;
#   (d) load balancer que nao e do tipo "network" e rejeitado pela postcondition.
#
# Roda sem AWS: usa mock_provider e command = plan (sem credenciais, sem state remoto).
#
# NAO esta no workflow de proposito: alterar o terraform.yml faria o merge deste
# PR disparar o workflow e ligar o EKS. Rodar manualmente:
#   terraform -chdir=api-gateway init -backend=false
#   terraform -chdir=api-gateway test

mock_provider "aws" {}

override_data {
  target = data.terraform_remote_state.auth_lambda
  values = {
    outputs = { function_arn = "arn:aws:lambda:us-east-1:123456789012:function:oficina-auth" }
  }
}

override_data {
  target = data.aws_lb.ingress
  values = {
    arn                = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/a1b2/abc"
    dns_name           = "a1b2-abc.elb.us-east-1.amazonaws.com"
    load_balancer_type = "network"
  }
}

run "sem_nlb" {
  command = plan

  assert {
    condition     = keys(aws_api_gateway_stage.environment) == ["prod"]
    error_message = "deve existir somente a stage prod"
  }
  assert {
    condition     = length(data.aws_lb.ingress) == 0 && length(aws_api_gateway_vpc_link.eks) == 0
    error_message = "sem NLB nao deve haver data aws_lb nem VPC Link"
  }
  assert {
    condition     = length(aws_api_gateway_resource.proxy) == 0 && length(aws_api_gateway_resource.auth_proxy) == 0
    error_message = "sem NLB nao deve haver {proxy+} nem /auth/{proxy+}"
  }
}

run "discover_nlb" {
  command = plan

  variables {
    discover_nlb = true
  }

  assert {
    condition     = length(aws_api_gateway_vpc_link.eks) == 1
    error_message = "discover_nlb deve criar 1 VPC Link"
  }
  assert {
    condition     = length(aws_api_gateway_resource.proxy) == 1 && aws_api_gateway_resource.proxy[0].path_part == "{proxy+}"
    error_message = "{proxy+} deve existir"
  }
  assert {
    condition     = length(aws_api_gateway_resource.auth_proxy) == 1 && aws_api_gateway_resource.auth_proxy[0].path_part == "{proxy+}"
    error_message = "/auth/{proxy+} deve existir"
  }
  assert {
    condition     = length(aws_api_gateway_integration.proxy) == 1 && length(aws_api_gateway_integration.auth_proxy) == 1
    error_message = "integracoes de proxy devem existir"
  }
}

run "nlb_arn_informado" {
  command = plan

  variables {
    nlb_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/a1b2/abc"
  }

  assert {
    condition     = length(data.aws_lb.ingress) == 1 && data.aws_lb.ingress[0].arn == var.nlb_arn
    error_message = "data.aws_lb.ingress deve usar o nlb_arn informado"
  }
  assert {
    condition     = length(aws_api_gateway_vpc_link.eks) == 1
    error_message = "nlb_arn deve criar 1 VPC Link"
  }
  assert {
    condition     = length(aws_api_gateway_resource.proxy) == 1 && length(aws_api_gateway_resource.auth_proxy) == 1
    error_message = "{proxy+} e /auth/{proxy+} devem existir"
  }
}

run "lb_nao_network_rejeitado" {
  command = plan

  variables {
    nlb_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/x/y"
  }

  override_data {
    target = data.aws_lb.ingress
    values = {
      arn                = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/x/y"
      dns_name           = "x.elb.amazonaws.com"
      load_balancer_type = "application"
    }
  }

  expect_failures = [data.aws_lb.ingress]
}
