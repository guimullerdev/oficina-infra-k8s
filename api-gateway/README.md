# api-gateway

Porta de entrada da oficina: roteia a autenticação por CPF para a Lambda e as
demais rotas para a aplicação no EKS.

Raiz Terraform separada da do cluster (`../`), com state próprio — o Gateway
depende da Lambda e do Service da aplicação, que têm ciclo de vida diferente
do EKS. Ver ADR 0006.

## O que ele roteia

```
Cliente → API Gateway
            ├─ POST /auth/cpf  → Lambda (alias do stage: homolog | prod)
            └─ ANY  /{proxy+}  → Service da app no EKS, via VPC Link
```

Um stage por ambiente (`/homolog`, `/prod`). A mesma integração serve aos
dois: `${stageVariables.alias}` faz cada stage invocar o alias correspondente
da Lambda, sem duplicar definição (ADR 0002).

## O Gateway não valida token

Ele roteia; quem autoriza é a aplicação (`JwtAuthGuard` + `RolesGuard`). A
regra real não é só "token válido", é "esta role pode esta operação" e "este
cliente só vê o próprio `sub`" — lógica que depende de dados de domínio e já
existe na app. Duplicá-la aqui criaria dois lugares para divergir. Detalhes e
trade-off na ADR 0006.

`POST /auth/cpf` é a exceção óbvia: é onde o token é obtido.

## Ordem de provisionamento

Este módulo lê o state de outros dois, então precisa vir depois deles:

1. `oficina-auth-lambda` — de onde sai o ARN da função
2. `../` (cluster EKS) — de onde saem as subnets
3. **este módulo**

## Rotas da aplicação são opcionais no primeiro apply

O VPC Link aponta para o NLB do Service da aplicação, que só existe depois do
primeiro deploy do repo da app. Por isso `nlb_arn` é variável:

- **vazia** (padrão): sobe só a rota de autenticação — o `apply` funciona
- **preenchida**: as rotas `/{proxy+}` para o cluster são criadas

Sem isso, seria impossível provisionar a infraestrutura antes de a aplicação
estar no ar.

## Como rodar

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Depois do primeiro deploy da aplicação, pegue o NLB e reaplique:

```bash
HOST=$(kubectl get svc oficina-api -n prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# O VPC Link espera o ARN do load balancer, não o de um listener:
NLB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='$HOST'].LoadBalancerArn" --output text)

terraform apply -var="nlb_arn=$NLB_ARN"
```

Para descobrir a URL pública de cada ambiente:

```bash
terraform output invoke_urls
terraform output auth_endpoints
```

## Documentação relacionada

No repo da aplicação (`TECH-CHALLENGE-FASE-ONE/docs/`):

- ADR 0006 — esta decisão, com os trade-offs
- ADR 0002 — estratégia de ambientes (namespaces, aliases, stages)
- ADR 0001 — padrão de comunicação entre os repos
- `docs/diagrams/0002-sequencia-autenticacao-cpf.md` — o fluxo que passa por aqui
