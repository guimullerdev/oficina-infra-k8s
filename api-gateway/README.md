# api-gateway

Porta de entrada da oficina: roteia a autenticação por CPF para a Lambda e,
quando habilitado, as demais rotas para a aplicação no EKS.

Raiz Terraform separada da do cluster (`../`), com state próprio — o Gateway
depende da Lambda e, no caminho com NLB, do ingress-nginx que o cluster sobe.
Esses têm ciclo de vida diferente do EKS. Ver ADR 0006.

## O que ele roteia

```
Cliente → API Gateway (stage prod)
            ├─ POST /auth/cpf        → Lambda (alias prod)
            ├─ ANY  /auth/{proxy+}   → ingress-nginx no EKS, via VPC Link   (com NLB)
            └─ ANY  /{proxy+}        → ingress-nginx no EKS, via VPC Link   (com NLB)
```

Uma stage só, `prod` (`environments = ["prod"]` em `variables.tf`).
`${stageVariables.alias}` faz a stage invocar o alias `prod` da Lambda, sem
duplicar a integração (ADR 0002). O alias `homolog` da Lambda continua
existindo, mas o API Gateway não o usa mais.

## O Gateway não valida token

Ele roteia; quem autoriza é a aplicação (`JwtAuthGuard` + `RolesGuard`). A
regra real não é só "token válido", é "esta role pode esta operação" e "este
cliente só vê o próprio `sub`" — lógica que depende de dados de domínio e já
existe na app. Duplicá-la aqui criaria dois lugares para divergir. Detalhes e
trade-off na ADR 0006.

`POST /auth/cpf` é a exceção óbvia: é onde o token é obtido.

## Ordem de provisionamento

1. `oficina-auth-lambda` — de onde sai o ARN da função (obrigatório)
2. `../` (cluster EKS) com o ingress-nginx instalado pelo pipeline do cluster
   — o NLB só existe depois disso (obrigatório só para o caminho com NLB)
3. **este módulo**

## Dois caminhos de apply

Rode os comandos dentro de `api-gateway/`.

```bash
terraform init -backend-config=backend.hcl
```

### 1. Sem NLB (padrão)

Sobe só `POST /auth/cpf` → Lambda. Não depende do cluster:

```bash
terraform plan
terraform apply
```

### 2. Com NLB

Cria o VPC Link, `/{proxy+}` e `/auth/{proxy+}`, ambos com `HTTP_PROXY` pelo
VPC Link. O path vai completo para a app, sem a stage. `/auth/cpf` continua na
Lambda, porque o recurso mais específico vence.

Há duas formas de informar o NLB:

- **Descoberta por tag** (`discover_nlb`): o cloud provider do EKS grava nele
  as tags abaixo, e o plan procura o load balancer que as tem:
  - `kubernetes.io/service-name = ingress-nginx/ingress-nginx-controller`
  - `kubernetes.io/cluster/oficina-cluster = owned`

  O plan falha se 0 ou mais de 1 NLB casar.

  ```bash
  terraform plan -var="discover_nlb=true"
  terraform apply -var="discover_nlb=true"
  ```

- **Override por ARN** (`nlb_arn`): precede a descoberta. O VPC Link espera o
  ARN do load balancer, não o de um listener.

  ```bash
  terraform apply -var="nlb_arn=<ARN do load balancer>"
  ```

Para conferir as tags de um NLB:

```bash
aws elbv2 describe-tags --resource-arns <ARN do load balancer>
```

Para listar os NLBs da conta (e pegar o ARN e o DNS):

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Type=='network'].[LoadBalancerArn,DNSName]" \
  --output text
```

### Ingress dos serviços: sem `host:`

Os `Ingress` dos serviços da aplicação devem ser **sem `host:`**. O API Gateway
envia o DNS do NLB no header `Host`, então uma regra com `host:` não casa e o
ingress-nginx responde 404.

## Runbook: VPC Link preso

Ao trocar de NLB, o VPC Link é recriado (`create_before_destroy`). Se o apply
falhar porque o VPC Link está em uso por um deployment:

```bash
# id da API
terraform output -raw api_id

# cria um deployment novo para a stage prod
aws apigateway create-deployment --rest-api-id <id> --stage-name prod

# lista os deployments e apaga os soltos que referenciem o link antigo
aws apigateway get-deployments --rest-api-id <id>
aws apigateway delete-deployment --rest-api-id <id> --deployment-id <deployment-id>

# reaplica
terraform apply
```

## Teardown

Antes de destruir o cluster, remova o ingress-nginx e espere o NLB sumir:

```bash
helm uninstall ingress-nginx -n ingress-nginx
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Type=='network'].[LoadBalancerArn,DNSName]" \
  --output text
```

Se o cluster for destruído com o NLB ainda existindo, o NLB fica órfão. Ele
continua com as tags de descoberta, e o próximo plan com `discover_nlb=true`
pode achar dois NLBs e falhar.

## Outputs

Para descobrir a URL pública da stage:

```bash
terraform output invoke_urls
terraform output auth_endpoints
terraform output rotas_da_app_expostas
terraform output nlb_dns_name
```

`auth_endpoints` existe com ou sem NLB. `rotas_da_app_expostas` diz se as rotas
da app foram criadas.

## Documentação relacionada

No repo `oficina-os-service` (`docs/`):

- ADR 0006 — esta decisão, com os trade-offs
- ADR 0002 — estratégia de ambientes (namespaces, aliases, stages)
- ADR 0001 — padrão de comunicação entre os repos
- `docs/diagrams/0002-sequencia-autenticacao-cpf.md` — o fluxo que passa por aqui
