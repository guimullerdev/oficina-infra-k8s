# mensageria

Tópicos SNS compartilhados dos microsserviços da oficina.

| Tópico | Output do ARN |
|---|---|
| `oficina-os-events` | `os_events_topic_arn` |
| `oficina-billing-events` | `billing_events_topic_arn` |
| `oficina-execucao-events` | `execucao_events_topic_arn` |

Só os tópicos (Standard, sem KMS, sem topic policy). Fila, DLQ, subscription e
IAM são do repo de cada serviço (ADR 0007).

## Por que um root compartilhado

O tópico é a peça que os dois lados conhecem: quem publica e quem consome. Se
cada serviço criasse o tópico que consome, o primeiro apply entraria em
deadlock de ordem — o publicador precisaria do ARN de um tópico que só existe
depois de o consumidor ser aplicado, e vice-versa. Com o barramento num root
próprio, ele sobe primeiro e os serviços só leem os ARNs.

## Como rodar

Aplicado à mão; o push na `main` ignora `mensageria/**`.

```bash
terraform -chdir=mensageria init -backend-config=backend.hcl
terraform -chdir=mensageria apply
```

Para ler os ARNs:

```bash
terraform -chdir=mensageria output -json
```
