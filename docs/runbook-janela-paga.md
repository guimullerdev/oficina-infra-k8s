# Runbook — janela paga (reconstruir o ambiente)

Sobe o ambiente único `prod` do zero e prova a rota até o cluster. EKS e RDS
ficam ligados só durante a janela (EKS ~US$ 0,18/h; o RDS `db.t4g.micro` cai no
free tier). SNS e API Gateway sobrevivem ao teardown e não custam parado.

Ordem: **RDS → EKS + ingress → túnel → bootstrap dos bancos → secrets → fila do
OS → deploy → API Gateway → verificação → teardown.** O túnel para o RDS
privado é um pod `socat` no próprio EKS (sem instância SSM, sem plugin, sem
expor o RDS), por isso o EKS sobe antes do bootstrap.

Convenções: comandos a partir de `Documents/Github/FIAP/`. Nada aqui imprime
senha: as URLs de banco vão por pipe direto para `gh secret set`.

## 0. Antes de ligar (sem custo)

- `aws sts get-caller-identity` mostra `oficina-deploy`.
- Os PRs do ingress (`oficina-infra-k8s#10`) e do API Gateway
  (`oficina-infra-k8s#11`) estão abertos com checks verdes e ainda **sem merge**.
- `gh secret list --repo guimullerdev/oficina-infra-k8s` tem `NEW_RELIC_LICENSE_KEY`.
- Nenhum cluster, RDS ou instância rodando:
  `aws eks list-clusters`, `aws rds describe-db-instances`.
- Os 3 tópicos SNS existem (`terraform -chdir=oficina-infra-k8s/mensageria output -json`).

## 1. RDS (oficina-infra-db, raiz)

Aplica à mão: o push só dispara apply para `*.tf` da raiz, e nada mudou nela.

```bash
cd oficina-infra-db && git checkout main && git pull
terraform init -backend-config=backend.hcl
terraform apply
```

Confirmar: `aws rds describe-db-instances` com 1 instância `available` e
`terraform output -raw db_address`. ~10 min.

## 2. EKS + ingress-nginx

Merge do `oficina-infra-k8s#10` **sem `[skip ci]`**: o push na `main` roda o
apply (cluster, nós, add-ons, namespace `prod`, ingress-nginx com `--wait`,
New Relic). ~20 min. Acompanhar com `gh run watch`.

```bash
aws eks update-kubeconfig --name oficina-cluster --region us-east-1
kubectl get nodes                       # 2 Ready
kubectl get ns prod
kubectl get ingressclass nginx
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP = internal-...elb...
aws elbv2 describe-load-balancers --query "LoadBalancers[].[Scheme,Type]" --output text   # internal network
```

Se o `helm --wait` estourar o timeout, o Service não ganhou hostname:
`kubectl -n ingress-nginx describe svc ingress-nginx-controller` mostra o erro do
cloud provider. Se o NLB não tiver as tags da descoberta
(`aws elbv2 describe-tags --resource-arns <arn>`), usar `-var nlb_arn=` no passo 8.

## 3. Túnel para o RDS (pod socat)

```bash
RDS=$(terraform -chdir=oficina-infra-db output -raw db_address)
kubectl -n prod run pg-proxy --image=alpine/socat --restart=Never -- \
  tcp-listen:5432,fork,reuseaddr tcp-connect:${RDS}:5432
kubectl -n prod wait --for=condition=Ready pod/pg-proxy --timeout=120s
kubectl -n prod port-forward pod/pg-proxy 5432:5432      # deixar aberto neste terminal
```

O SG do RDS aceita 5432 do CIDR da VPC e pods recebem IP da VPC. Se der
timeout, conferir a regra do SG antes de qualquer outra coisa.

## 4. Bootstrap dos bancos (outro terminal)

```bash
cd oficina-infra-db
terraform -chdir=bootstrap-db init -backend-config=backend.hcl
terraform -chdir=bootstrap-db state list
```

O state pode ter as chaves antigas (RDS destruído antes). Se `state list` mostrar
`["homolog"]`/`["prod"]`, remover **antes** de qualquer plan:

```bash
terraform -chdir=bootstrap-db state rm \
  'random_password.app_user["homolog"]' 'random_password.app_user["prod"]' \
  'postgresql_role.app_user["homolog"]' 'postgresql_role.app_user["prod"]' \
  'postgresql_database.this["homolog"]' 'postgresql_database.this["prod"]'
```

```bash
terraform -chdir=bootstrap-db apply -var db_host_override=localhost:5432
terraform -chdir=bootstrap-db plan -detailed-exitcode -var db_host_override=localhost:5432   # exit 0
```

Prova do isolamento (Docker no host; a senha não aparece no terminal):

```bash
url() { terraform -chdir=bootstrap-db output -json database_urls | jq -r ".$1"; }
pw()  { url "$1" | sed -E 's#^postgresql://[^:]+:([^@]+)@.*#\1#'; }
q()   { docker run --rm -e PGPASSWORD="$(pw "$1")" postgres:16-alpine \
          psql -h host.docker.internal -p 5432 -U "oficina_$1_app" -d "$2" -tAc "select 1" 2>&1 | tail -1; }
q os oficina_os            # 1
q billing oficina_billing  # 1
q os oficina_billing       # FATAL: permission denied for database
q billing oficina_os       # FATAL: permission denied for database
```

Fechar o túnel (Ctrl-C) e `kubectl -n prod delete pod pg-proxy`.

## 5. Secrets

```bash
cd oficina-infra-db
url() { terraform -chdir=bootstrap-db output -json database_urls | jq -r ".$1"; }
url os | gh secret set DATABASE_URL --env prod --repo guimullerdev/oficina-os-service
url billing | gh secret set DATABASE_URL --env prod --repo guimullerdev/oficina-billing-service
url os | gh secret set DATABASE_URL_PROD --repo guimullerdev/oficina-auth-lambda
url os | gh secret set DATABASE_URL_HOMOLOG --repo guimullerdev/oficina-auth-lambda   # a validation exige não vazio; o alias homolog segue existindo
```

`DATABASE_URL_HOMOLOG` aponta para `oficina_os` de propósito (D-INF-6).

## 6. Fila do OS (oficina-os-service, Fase 6)

```bash
cd oficina-os-service/terraform
M=../../oficina-infra-k8s/mensageria
terraform init -backend-config=backend.hcl
terraform plan \
  -var os_events_topic_arn=$(terraform -chdir=$M output -raw os_events_topic_arn) \
  -var billing_events_topic_arn=$(terraform -chdir=$M output -raw billing_events_topic_arn) \
  -var execucao_events_topic_arn=$(terraform -chdir=$M output -raw execucao_events_topic_arn)
```

Esperado: 2 filas, 2 subscriptions, queue policy + IAM policy, 0 destroy.
`apply` com os mesmos `-var`, depois:

```bash
terraform output -raw queue_url | gh secret set SQS_QUEUE_URL --env prod --repo guimullerdev/oficina-os-service
terraform -chdir=$M output -raw os_events_topic_arn | gh secret set SNS_TOPIC_ARN --env prod --repo guimullerdev/oficina-os-service
aws sqs get-queue-attributes --queue-url $(terraform output -raw queue_url) --attribute-names RedrivePolicy   # maxReceiveCount 3
```

`SQS_CONSUMER_ENABLED` continua `"false"` no configmap até validar a fila.

### 6b. Fila do billing (oficina-billing-service/terraform)

```bash
cd oficina-billing-service/terraform
M=../../oficina-infra-k8s/mensageria
terraform init -backend-config=backend.hcl
terraform plan \
  -var os_events_topic_arn=$(terraform -chdir=$M output -raw os_events_topic_arn) \
  -var billing_events_topic_arn=$(terraform -chdir=$M output -raw billing_events_topic_arn)
```

Esperado: 2 filas, 1 subscription (só `oficina-os-events`), queue policy, IAM
policy e usuário `oficina-billing-service-pod`, 0 destroy. `apply` com os mesmos
`-var`, depois copiar as saídas para o environment `prod` do billing. A access key
não fica no state (igual ao OS): é criada à mão e vai direto para os secrets.

```bash
terraform output -raw queue_url | gh secret set SQS_QUEUE_URL --env prod --repo guimullerdev/oficina-billing-service
terraform -chdir=$M output -raw billing_events_topic_arn | gh secret set SNS_TOPIC_ARN --env prod --repo guimullerdev/oficina-billing-service
read -r KID KSECRET < <(aws iam create-access-key --user-name $(terraform output -raw service_user_name) --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
gh secret set POD_AWS_ACCESS_KEY_ID --env prod --repo guimullerdev/oficina-billing-service --body "$KID"
gh secret set POD_AWS_SECRET_ACCESS_KEY --env prod --repo guimullerdev/oficina-billing-service --body "$KSECRET"
unset KID KSECRET
aws sqs get-queue-attributes --queue-url $(terraform output -raw queue_url) --attribute-names RedrivePolicy   # maxReceiveCount 3
```

### 6c. Fila e tabela do execução (oficina-execucao-service/terraform)

```bash
cd oficina-execucao-service/terraform
grep '^ *key' backend.hcl     # tem que ser execucao-service/terraform.tfstate, antes do init
M=../../oficina-infra-k8s/mensageria
terraform init -backend-config=backend.hcl
terraform plan \
  -var os_events_topic_arn=$(terraform -chdir=$M output -raw os_events_topic_arn) \
  -var execucao_events_topic_arn=$(terraform -chdir=$M output -raw execucao_events_topic_arn)
```

Esperado: fila `oficina-execucao-queue` com DLQ `oficina-execucao-queue-dlq`, subscription
em `oficina-os-events`, queue policy, IAM policy e usuário do pod, 0 destroy. A tabela
`oficina-execucao` não pode ser recriada se sobreviveu ao teardown (fica no state).
`apply` com os mesmos `-var`, depois copiar as saídas para o environment `prod` do execução.

```bash
terraform output -raw queue_url | gh secret set SQS_QUEUE_URL --env prod --repo guimullerdev/oficina-execucao-service
gh secret set DYNAMODB_TABLE --env prod --repo guimullerdev/oficina-execucao-service --body oficina-execucao
terraform -chdir=$M output -raw execucao_events_topic_arn | gh secret set SNS_TOPIC_ARN --env prod --repo guimullerdev/oficina-execucao-service
read -r KID KSECRET < <(aws iam create-access-key --user-name $(terraform output -raw service_user_name) --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
gh secret set POD_AWS_ACCESS_KEY_ID --env prod --repo guimullerdev/oficina-execucao-service --body "$KID"
gh secret set POD_AWS_SECRET_ACCESS_KEY --env prod --repo guimullerdev/oficina-execucao-service --body "$KSECRET"
unset KID KSECRET
```

`JWT_SECRET` tem que ser o mesmo do `oficina-os-service` (o GitHub não devolve o valor,
então usar a mesma origem que foi usada no OS; não imprimir):

```bash
<origem-do-jwt-secret> | gh secret set JWT_SECRET --env prod --repo guimullerdev/oficina-execucao-service
```

## 7. Deploy do OS

O pacote GHCR `oficina-os-service` só existe depois do primeiro push e nasce
**privado**: o primeiro deploy morre em `ImagePullBackOff`. Esperar isso.

1. `gh workflow run ci-cd.yml --repo guimullerdev/oficina-os-service --ref main`
   (o job de build publica a imagem; o deploy vai falhar no pull).
2. No GitHub: Packages → `oficina-os-service` → Package settings → Change
   visibility → Public.
3. Apagar a migration Job falhada (Jobs são imutáveis e o nome carrega o SHA):
   `kubectl -n prod delete job -l app=oficina-os-service,component=migration`.
4. Reexecutar: `gh run rerun <id> --failed --repo guimullerdev/oficina-os-service`.

Confirmar: Job de migration `Complete` e
`kubectl -n prod rollout status deployment/oficina-os-service --timeout=300s`.
A migration `fronteira_dados` dropa tabelas e é irreversível: só roda no
`oficina_os` recém-criado e vazio.

### 7b. Deploy do billing

Mesmo caso do OS: o pacote GHCR `oficina-billing-service` nasce **privado** e o
primeiro deploy morre em `ImagePullBackOff`.

1. `gh workflow run ci-cd.yml --repo guimullerdev/oficina-billing-service --ref main`
   (o job de build publica a imagem; o deploy vai falhar no pull).
2. No GitHub: Packages → `oficina-billing-service` → Package settings → Change
   visibility → Public.
3. Apagar o Job de migration falhado:
   `kubectl -n prod delete job -l app=oficina-billing-service,component=migration`.
4. Reexecutar: `gh run rerun <id> --failed --repo guimullerdev/oficina-billing-service`.

Confirmar (`<sha>` é o SHA do deploy):

```bash
kubectl -n prod get pods -l app=oficina-billing-service                  # 2 Ready
kubectl -n prod wait --for=condition=complete job/oficina-billing-migrate-<sha> --timeout=300s
kubectl -n prod rollout status deployment/oficina-billing-service --timeout=300s
```

### 7c. Deploy do execução

Mesmo caso do OS e do billing: o pacote GHCR `oficina-execucao-service` nasce **privado**
e o primeiro deploy morre em `ImagePullBackOff`. Não há migration (a tabela é DynamoDB).

1. `gh workflow run ci-cd.yml --repo guimullerdev/oficina-execucao-service --ref main`
   (o deploy vai falhar no pull).
2. No GitHub: Packages → `oficina-execucao-service` → Package settings → Change
   visibility → Public.
3. Reexecutar: `gh run rerun <id> --failed --repo guimullerdev/oficina-execucao-service`.

Confirmar: `kubectl -n prod rollout status deployment/oficina-execucao-service --timeout=300s`.

Ingress do serviço: só `/execucao`. Nunca declarar `/health` nem `/api` (o `/health` é do OS).

## 8. API Gateway

Merge do `oficina-infra-k8s#11` (não dispara nada: `api-gateway/**` está no
`paths-ignore`). Depois, na `main` atualizada:

```bash
cd oficina-infra-k8s
terraform -chdir=api-gateway init -backend-config=backend.hcl
terraform -chdir=api-gateway plan -var discover_nlb=true
```

Esperado: `8 to add, 1 to change, 3 to destroy` (VPC Link, 2 resources, 2
methods, 2 integrations, deployment novo; destroy de stage e permissão `homolog`
e do deployment antigo). 0 ou mais de 1 NLB casando = falha do plan:
usar `-var nlb_arn=<arn>`. Aplicar com o mesmo `-var`.

Se o apply reclamar de VPC Link "em uso" por um deployment:

```bash
aws apigateway create-deployment --rest-api-id 7eu2kz40xj --stage-name prod --description unpin-vpc-link
aws apigateway get-deployments --rest-api-id 7eu2kz40xj
# delete-deployment dos soltos (não o da stage) e reaplicar
```

## 9. Auth por CPF

O Lambda lê o secret na hora do apply: reexecutar o último run da `main`
(o repo não tem `workflow_dispatch`):

```bash
gh run rerun $(gh run list --repo guimullerdev/oficina-auth-lambda --branch main -L1 --json databaseId -q '.[0].databaseId') --repo guimullerdev/oficina-auth-lambda
```

A tabela `clientes` só existe depois da migration do passo 7; precisa de um
CPF semeado (`oficina-os-service/scripts/preparar-demo.sh`).

## 10. Verificação (critérios da Fase 4)

```bash
API=https://7eu2kz40xj.execute-api.us-east-1.amazonaws.com/prod
curl -i $API/health                       # 200 com o serviço no ar (404 do nginx sem ele)
curl -i $API/billing/health               # 200 com o billing no ar
curl -i $API/execucao/health              # 200 com o execução no ar
kubectl -n prod get pods -l app=oficina-execucao-service                             # 2 Ready
aws sqs get-queue-attributes --queue-url $(aws sqs get-queue-url --queue-name oficina-execucao-queue-dlq --query QueueUrl --output text) --attribute-names ApproximateNumberOfMessages   # 0
curl -i -X POST $API/auth/cpf -H 'content-type: application/json' -d '{"cpf":"<cpf semeado>"}'   # 200
aws apigateway get-stages --rest-api-id 7eu2kz40xj --query 'item[].stageName'   # só prod
```

Mais: `\l` com `oficina_os` e `oficina_billing` (sem `oficina_homolog`/`oficina_prod`),
o `permission denied` do passo 4, 1 NLB `internal`, `kubectl get ingressclass nginx`.
Confirmar os riscos: tags do NLB, Ingress dos serviços **sem `host:`**,
`/auth/register|login|refresh` do OS respondendo pelo Gateway.

## 11. Teardown (depois de gravar o vídeo; D-INF-9)

Ordem importa: o NLB do ingress é criado pelo Service, não pelo Terraform; sem
desinstalar antes, ele fica órfão cobrando e a próxima descoberta por tag acha dois.

```bash
helm uninstall ingress-nginx -n ingress-nginx
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'   # esperar vazio
terraform -chdir=oficina-infra-k8s/api-gateway apply            # sem -var: volta a só /auth/cpf
terraform -chdir=oficina-infra-k8s destroy                      # EKS
# execução: a tabela oficina-execucao sobrevive ao EKS; o destroy é no repo do serviço
(cd oficina-execucao-service/terraform && terraform destroy -var-file=terraform.tfvars)   # tabela, fila, DLQ e usuário IAM
terraform -chdir=oficina-infra-db destroy                       # RDS (sem snapshot final)
aws eks list-clusters; aws rds describe-db-instances; aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running
```

Ficam vivos: tópicos SNS, filas SQS (OS, billing e execução, sem custo parado),
tabela DynamoDB `oficina-execucao` (sai só no destroy do repo do serviço) e usuários
IAM dos pods, API Gateway só com `/auth/cpf`, Lambda,
bucket de state. Conferir snapshots manuais do RDS (`aws rds describe-db-snapshots`).
