# observabilidade

Alertas e monitoramento externo no New Relic, como código.

Raiz Terraform separada, com state próprio — mesmo padrão do `api-gateway/`.
O motivo é ciclo de vida: alerta muda quando muda o que a aplicação emite,
não quando muda a infraestrutura do cluster. Misturar os dois faria qualquer
ajuste de limiar disputar lock com um `apply` de EKS.

## Por que mora neste repositório

É este repo que já instala o agente do New Relic no cluster (`nri-bundle` via
Helm, no pipeline). A ferramenta de observabilidade já é responsabilidade
daqui; o que faltava era a parte que não roda dentro do cluster.

O **dashboard** continua fora: vive versionado como JSON em
`TECH-CHALLENGE-FASE-ONE/docs/observabilidade/`, porque as queries dele
descrevem eventos que a aplicação emite e mudam junto com o código dela.

## O que é criado

| Recurso | Para quê |
|---|---|
| Política `Oficina — Tech Challenge Fase 4` | agrupa as condições, com incidente por condição |
| Condição `Falha no processamento de OS` | qualquer `os.processamento.falha` em 5 min |
| Condição `Falhas de requisição acima do normal` | mais de 5 `requisicao.falha` em 5 min |
| Condição `Aplicação parou de reportar transações` | nenhuma `Transaction` por 10 min |
| Monitor `Oficina — health (prod)` | consulta o `/health` no Gateway a cada 5 min, de duas regiões |
| Condição `Health check externo falhando` | duas falhas do monitor em 5 min |
| Destination + channel + workflow | leva o incidente para um e-mail |

Sem o workflow, uma condição que dispara só aparece na interface e não
notifica ninguém — é o passo que costuma faltar.

### Por que dois níveis de limiar

`os.processamento.falha` alerta na **primeira** ocorrência: qualquer 5xx numa
rota de ordem de serviço significa um cliente sem resposta, e o
`correlationId` no log leva direto à requisição. `requisicao.falha` cobre o
resto da API, inclusive rotas de leitura, e por isso tolera até 5 em cinco
minutos antes de abrir incidente.

### Por que o Synthetics, se já existe o agente

O agente dentro do pod só sabe dizer que a aplicação responde a quem já
chegou nela. O Synthetics atravessa o caminho inteiro — API Gateway, VPC
Link, NLB, pod — e é o único que percebe uma quebra nas camadas de rede entre
eles. A `validation_string` existe pelo mesmo motivo: uma página de erro do
Gateway com status 200 passaria numa checagem que só olha o código.

## Integração AWS (SQS)

`integracao-aws.tf` vincula a conta AWS ao New Relic por **API polling** e
coleta só o SQS: filas com prefixo `oficina`, na região `var.aws_region`,
a cada 5 minutos (`metrics_polling_interval = 300`). Os dados chegam como
`QueueSample`, com tags e inventário estendido. A primeira leitura aparece
em cerca de 15 minutos após o apply.

`iam.tf` cria a role `NewRelicIntegrations`, que o New Relic assume. A
trust policy aceita apenas a conta AWS do New Relic (`754728514883`) e exige
`sts:ExternalId` igual ao id da conta New Relic, o que evita o problema do
*confused deputy*. A permissão é somente leitura: listar filas, ler
atributos e tags, e consultar métricas no CloudWatch.

A role e a integração **sobrevivem ao teardown do EKS**: pertencem a esta
raiz, não à do cluster, e não geram custo (IAM é gratuito; o polling usa
só a API do CloudWatch).

## Pré-requisitos

- Terraform >= 1.9
- Credenciais AWS no ambiente, com permissão para criar role IAM
- Uma **User key** do New Relic (`NRAK-...`)

A User key **não** é a license key. A license key (`NEW_RELIC_LICENSE_KEY`,
que está no Secret do Kubernetes) só permite que os agentes *enviem* dados;
criar alerta e monitor exige uma User key, a única aceita pela NerdGraph para
escrita. Criar em https://one.newrelic.com/api-keys → *Create a key* → tipo
**User**.

As duas variáveis têm `validation`: valor vazio ou que não comece com `NRAK-`
falha no plan, em vez de aplicar e falhar com erro de autenticação obscuro.

## Como aplicar

```bash
terraform init -backend-config=backend.hcl

# Credenciais AWS (necessárias para a role da integração), por exemplo:
export AWS_PROFILE=meu-perfil

# Lê a chave sem ecoar no terminal nem gravar no histórico do shell
read -s TF_VAR_new_relic_api_key && export TF_VAR_new_relic_api_key
export TF_VAR_email_notificacao='quem-recebe@exemplo.com'

terraform plan
terraform apply
```

## Pipeline

Não roda no CI hoje. O workflow do repositório cobre a raiz do cluster e
valida a do `api-gateway/`; incluir esta exigiria o secret `NEW_RELIC_API_KEY`
no repositório. Como alerta muda pouco depois de definido, o apply manual é
aceitável — e evita guardar mais uma credencial de escrita no CI do que o
necessário.

## Custo

Zero. Alertas e notificação por e-mail não são cobrados, e o tier free do New
Relic inclui verificações de Synthetics suficientes para um monitor a cada 5
minutos em duas regiões.
