# oficina-infra-k8s

> Repositório 3 de 4 — Tech Challenge Fase 3 (SOAT).

Terraform que provisiona o **cluster Kubernetes gerenciado (AWS EKS)** onde a
aplicação da oficina roda.

## Infraestrutura ativa

| Recurso | Identificador |
|---|---|
| Cluster EKS | `oficina-cluster` · Kubernetes 1.31 · `us-east-1` |
| Nós | 2 × `t3.small`, escalando até 4 |
| Namespaces | `prod` e `homolog`, um Deployment + HPA em cada |
| Add-ons | `coredns`, `kube-proxy`, `vpc-cni`, `metrics-server` |
| Agente de observabilidade | `nri-bundle` (New Relic) no namespace `newrelic` |
| API Gateway | `7eu2kz40xj`, stages `prod` e `homolog` |

Endpoints públicos (a porta de entrada de tudo):

- Produção: https://7eu2kz40xj.execute-api.us-east-1.amazonaws.com/prod
- Homologação: https://7eu2kz40xj.execute-api.us-east-1.amazonaws.com/homolog
- Dashboard: https://onenr.io/0qwykVVv1jn

```bash
aws eks update-kubeconfig --name oficina-cluster --region us-east-1
kubectl get pods -n prod
```

O acesso ao cluster é concedido por **EKS access entry** — quem cria o cluster
não vira administrador dele automaticamente, e sem a entrada o `kubectl`
responde `the server has asked for the client to provide credentials`.

> Infraestrutura de curso, provisionada para a avaliação e destruída depois.
> O EKS cobra por hora de control plane, então o cluster não fica de pé
> indefinidamente — tudo aqui é reproduzível com um `terraform apply`.

## Escopo: o que está aqui e o que não está

Este repositório cuida **só da infraestrutura do cluster**. Os manifestos da
aplicação não vivem aqui.

| Aqui (infraestrutura) | No repo da app (`TECH-CHALLENGE-FASE-ONE`) |
|---|---|
| Cluster EKS e versão do Kubernetes | `Deployment`, `Service` |
| Node group e seu autoscaling | `HPA` |
| Rede (VPC, subnets) | `ConfigMap`, `Secret` |
| Add-ons (`metrics-server`, CNI, CoreDNS, kube-proxy) | Job de migration do Prisma |
| Namespaces `homolog` e `prod` | O pipeline que aplica tudo isso |
| Agente do New Relic (métricas do cluster) | |
| **API Gateway** (em `api-gateway/`, state próprio) | |

A fronteira segue a ADR 0001 e foi confirmada em Q&A oficial da FIAP: o repo
de infraestrutura Kubernetes provisiona o ambiente; o ciclo de vida da
aplicação — incluindo o deploy dela — pertence ao repo da aplicação. Este
repo expõe outputs (endpoint, nome do cluster, CA, OIDC) e o pipeline da app
os consome para autenticar e aplicar seus próprios manifestos.

Este repositório tem **três raízes Terraform**, com states independentes:

| Diretório | O que provisiona | Quando aplicar |
|---|---|---|
| `.` (raiz) | Cluster EKS, node group, add-ons | Primeiro |
| `api-gateway/` | API Gateway: `POST /auth/cpf` → Lambda, `/{proxy+}` → EKS | Depois da Lambda e do cluster (ver o README de lá) |
| `observabilidade/` | Alertas e monitor externo de uptime no New Relic | Depois do Gateway, a qualquer momento (ver o README de lá) |

States separados porque os ciclos de vida são diferentes: alerta muda quando
muda o que a aplicação emite, e o Gateway depende de recursos de outro
repositório. Um state só faria qualquer ajuste de limiar disputar lock com um
apply de cluster.

## Stack

- Terraform >= 1.9, provider `hashicorp/aws` ~> 5.0
- AWS EKS 1.31, node group gerenciado em `t3.small`
- GitHub Actions para CI/CD
- New Relic (`nri-bundle` via Helm) para métricas de CPU/memória do cluster
- Provider `newrelic/newrelic` ~> 3.43 para alertas e monitoramento externo

## Decisões de infraestrutura

- **VPC default da conta**, não uma VPC dedicada. RDS (`oficina-infra-db`),
  Lambda (`oficina-auth-lambda`) e os pods do EKS precisam estar na mesma
  rede — o RDS é `publicly_accessible = false`, então só quem está dentro da
  VPC o alcança. Criar uma VPC própria aqui exigiria aplicar este repo antes
  do `infra-db`, que já está no ar, e criaria dependência de remote state
  entre os dois. Trade-off aceito para um projeto de curso com uma conta só.
- **Endpoint público do cluster habilitado** (além do privado): o pipeline da
  app roda em runner hospedado do GitHub, fora da VPC, e precisa alcançar a
  API do cluster para aplicar os manifestos. O acesso continua autenticado
  por IAM.
- **`metrics-server` é declarado explicitamente** como add-on. Ao contrário do
  GKE, o EKS **não** traz metrics-server por padrão — sem ele o HPA sobe, mas
  fica com métrica `<unknown>` e nunca escala, que é justamente o requisito
  de escalabilidade da fase (ADR 0003).
- **Namespaces e New Relic são aplicados fora do Terraform**, num segundo
  passo do pipeline com `kubectl`/`helm`. Usar os providers `kubernetes`/
  `helm` do Terraform criaria um problema de bootstrap: o provider precisa do
  endpoint de um cluster que ainda não existe no primeiro `apply`. A Fase 2
  já tinha esbarrado nisso e resolvido com apply em duas etapas; aqui a
  separação é explícita desde o começo.

## Pré-requisitos

- Terraform >= 1.9
- Credenciais AWS com permissão de EKS, EC2 (VPC/SG) e IAM
- Bucket S3 + tabela DynamoDB do backend já criados (bootstrap manual único —
  ver Fase 0 do plano)

## Como rodar

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Depois do cluster no ar, o segundo passo (que o pipeline faz sozinho):

```bash
aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region us-east-1
kubectl apply -f k8s/namespaces.yaml
```

> **Conta AWS Academy Learner Lab**: o ambiente bloqueia criação de IAM
> roles. Passe `existing_cluster_role_arn` e `existing_node_role_arn` com o
> ARN da `LabRole` — o Terraform pula a criação e reusa a role existente.

## Pipeline

`.github/workflows/terraform.yml`:

- **Pull request para `main`**: `fmt -check`, `validate` e `plan` — o plano é
  comentado automaticamente no PR. É o gate do merge.
- **Push em `main`** (pós-merge): `terraform apply`, depois
  `kubectl apply` dos namespaces e `helm upgrade` do agente New Relic.

Secrets necessários: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`NEW_RELIC_LICENSE_KEY` e — só em conta Learner Lab — `AWS_SESSION_TOKEN`,
`EKS_CLUSTER_ROLE_ARN`, `EKS_NODE_ROLE_ARN`.

## Outputs (contrato com os outros repos)

| Output | Quem consome |
|---|---|
| `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority` | Pipeline da app, para `aws eks update-kubeconfig` e aplicar manifestos |
| `cluster_oidc_issuer_url` | Permissão AWS via ServiceAccount (IRSA), se necessário |
| `vpc_id`, `subnet_ids` | API Gateway (Fase 6), para o VPC Link |
| `node_security_group_id` | Ajuste fino de acesso ao RDS, se um dia o SG for restringido |

A raiz `observabilidade/` expõe `policy_id`, `monitor_guid` e a lista de
condições criadas — úteis para anexar novas condições sem procurar na
interface, e para linkar o monitor no PDF de entrega.

## Custo

O control plane do EKS custa ~US$0,10/h (~US$73/mês) e **não é coberto pelo
free tier**, mais as instâncias do node group. Para um projeto de curso, vale
rodar `terraform destroy` fora das janelas de trabalho e da gravação do vídeo.

## Documentação relacionada

Vive no repo da aplicação (`TECH-CHALLENGE-FASE-ONE/docs/`):

- ADR 0001 — padrão de comunicação entre os repos (a fronteira acima)
- ADR 0002 — escalabilidade e separação de ambientes
- ADR 0003 — uso do HPA e o metrics-server
- ADR 0004 — organização dos logs e traces (o que os alertas consomem)
- ADR 0006 — o API Gateway: onde mora, por que não valida JWT, por que v1
- Diagrama de componentes: `docs/diagrams/0001-diagrama-componentes.md`
