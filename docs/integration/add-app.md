# Adicionar uma aplicação ao broker (usuário, prefixo e policy DLX)

O broker é dono de usuários, permissões e policies do vhost `dev`; o template é a fonte de verdade. Cada app recebe:
um usuário próprio, permissões restritas ao seu prefixo e uma policy de dead-letter para suas filas.
Exemplo genérico com a app `billing` (substitua pelo nome real; nada aqui altera outros projetos).

## 1. Convenção de nomes (steering `messaging-rabbitmq.md`)

- Prefixo da app: `billing.` (exchanges `billing.events`/`billing.dlx`, filas `billing.<finalidade>` e `billing.<finalidade>.dlq`).
- Permissões (regex): `^billing\.` em configure, write e read. A app publica nos exchanges de outros contextos só se
  receber permissão explícita de write neles (ex.: `^(billing|orders)\.`).

## 2. Editar `definitions/definitions.template.json`

1. Em `users`, acrescente o usuário com um placeholder de hash (sem senha no template):
   `{ "name": "billing-app", "password_hash": "__BILLING_APP_PASSWORD_HASH__", "hashing_algorithm": "rabbit_password_hashing_sha256", "tags": [] }`
2. Em `permissions`: `{ "user": "billing-app", "vhost": "dev", "configure": "^billing\.", "write": "^billing\.", "read": "^billing\." }`
3. Em `policies`, a DLX das filas de consumo (mesmo padrão do `smoke-dlx`):
   `{ "vhost": "dev", "name": "billing-dlx", "pattern": "^billing\.[^.]+$", "apply-to": "queues", "priority": 0, "definition": { "dead-letter-exchange": "billing.dlx", "dead-letter-strategy": "at-least-once", "overflow": "reject-publish", "delivery-limit": 5 } }`
   (`at-least-once` exige `overflow: reject-publish`; a DLQ e o `billing.dlx` são declarados pela app ou acrescentados em `exchanges`/`queues`/`bindings`).
4. Sem `tags` de management: a app só usa AMQP.

## 3. Segredo e render

1. Gere a senha da app e guarde no cofre/`.env` **da app** (nunca neste repositório). Para o `.env` deste broker, só se a
   app precisar existir no smoke: acrescente `RABBITMQ_BILLING_APP_PASSWORD` em `scripts/generate-env.sh` e o placeholder
   em `scripts/render-definitions.sh` (siga o `smoke-app`).
2. `./scripts/render-definitions.sh` gera `definitions.json` com o hash calculado.

## 4. Aplicar e verificar

```bash
docker compose restart rabbitmq        # o import só ocorre no boot e quando o arquivo mudou
docker compose run --rm provisioner    # remove obsoletos e valida; idempotente
./scripts/smoke-test.sh                # ou ao menos: rabbitmqctl list_permissions -p dev
```

A app conecta em `rabbitmq:5672` (rede Docker `workspace-messaging`, vhost `dev`) com `ClientProvidedName` do serviço.
Remover uma app: apague as entradas do template, repita o fluxo; o provisionador remove usuário e policy dentro dos vhosts do template.
