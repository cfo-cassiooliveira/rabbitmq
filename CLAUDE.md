> Índice de docs (specs, ADRs, comandos): [docs/INDEX.md](docs/INDEX.md)

# RabbitMQ — broker de mensageria local

> Herda a Constituição (`C:\Workspace\CLAUDE.md`) e o steering (`C:\Workspace\.claude\rules\`), em especial
> `messaging-rabbitmq.md`, `security.md` e `observability.md`. Projeto de infraestrutura (sem código de aplicação):
> aplicam-se Art. IV, VI, VII, X e XI.

## Produto

- **Propósito**: broker RabbitMQ 4.x (single-node, Docker) para os projetos do workspace, com configuração como código.
- **Usuários**: os serviços do workspace (AMQP) e o operador (UI de management, só em localhost).
- **Fora de escopo**: topologia de negócio dos apps (cada app declara a sua dentro do seu prefixo), Keycloak/OAuth2 na UI,
  cluster, TLS obrigatório (opcional por profile).

## Estrutura

```
docker-compose.yml          rabbitmq, provisioner, log-shipper (+ smoke, log-shipper-test, gelf-sink em profiles); redes workspace-messaging (compartilhada), rabbitmq-internal, rabbitmq-metrics (internas) e observability (externa)
config/rabbitmq.conf        configuração do broker (comentários PT-BR); config/enabled_plugins
config/fluent-bit/        fluent-bit.conf, parsers.conf e level.lua (nível GELF numérico) do coletor de logs (log-shipper)
config/tls.conf + docker-compose.tls.yml   TLS opcional (AMQPS 5671); scripts/generate-certs.sh e scripts/smoke-tls.sh
definitions/                definitions.template.json (versionado, sem segredos); definitions.json é gerado (gitignored)
provisioning/provision.sh   remove guest e itens obsoletos e valida o estado (idempotente), via API de management
scripts/generate-env.sh     gera o .env (0600) com segredos aleatórios e renderiza as definitions
scripts/render-definitions.sh  template -> definitions.json com password_hash calculado do .env
scripts/messaging-network.sh   confere a existência da rede workspace-messaging
scripts/observability-network.sh   garante a rede externa observability
scripts/logs-fallback-check.sh   logs locais retidos e backlog do coletor (somente leitura)
scripts/shipper-api.sh      consulta a API do coletor (imagem distroless, sem shell) a partir de um container descartável
scripts/backup-definitions.sh   exporta as definitions pela API (saída em backups/, gitignored, 0600)
scripts/e2e-graylog.sh      e2e real com o Graylog (só local, fora do CI); tests/e2e/graylog_check.py verifica o JSON
scripts/smoke-test.sh       teste ponta a ponta, incremental (a-e, j, l métricas, m logs, n fallback); tests/smoke/ = cliente pika, gelf-sink/ e logs-fallback.sh
docs/integration/           insumos Grafana (F01)/Graylog (F02) e add-app.md (usuário, prefixo, policy DLX)
.github/workflows/ci.yml    shellcheck, gitleaks, trivy fs/image, compose config, smoke, smoke TLS; .gitleaks.toml = exceções justificadas
docs/adr/                   decisões
```

## Comandos

```bash
./scripts/generate-env.sh          # .env + definitions.json (não sobrescreve um .env existente)
docker compose up -d --build       # broker (healthy) e provisionador
docker compose run --rm provisioner   # reexecuta o provisionamento (idempotente)
./scripts/smoke-test.sh            # verificação
```

## Regras deste projeto

- Imagem fixada por **tag + digest** (`rabbitmq:4.3-management`); atualizar = novo pull, novo digest, smoke verde.
- Segredos só no `.env` (gerado por script) e como **hash** em `definitions.json`; nunca no template, no compose ou em log.
- `guest` não existe: o provisionador o remove; o smoke prova a recusa por API e AMQP. Usuário por app, permissões por
  prefixo (`^<app>\.`), sem tags de management. O broker é dono de vhosts, usuários, permissões e policies; usuário
  fora do `definitions.json` é removido pelo provisionador.
- Portas só em `127.0.0.1`; EPMD/distribuição não são publicados; `mem_limit: 1g` com watermark absoluto de 600MiB.
- Quorum queues por padrão (metadata do vhost `dev`); DLX por policy (`dead-letter-strategy: at-least-once` exige
  `overflow: reject-publish`). A UI não é fonte de verdade: mudou a topologia, mude o template e rode o provisionador.
- Import de definitions é aditivo e só ocorre quando o arquivo muda (`skip_if_unchanged`): remoções vão no provisionador.
- Toda configuração entra por arquivo versionado, nunca só pela UI. Cada mudança roda o smoke test.
- Fim de linha LF (`.gitattributes`): scripts e configs rodam em containers Linux.
- Métricas: `rabbitmq_prometheus` na 15692 (loopback). Logs: `log.file` JSON em volume + `log-shipper` (Fluent Bit 4.2.8 distroless, tag+digest, Apache-2.0; sem healthcheck no compose: a sonda é `scripts/shipper-api.sh`)
  com buffer em disco e `Retry_Limit no_limits`; só o coletor entra na rede externa `observability` (criada por `scripts/observability-network.sh`).
  Subir antes: `./scripts/observability-network.sh`. Trivy do coletor: CRITICAL com correção bloqueia no CI; exceções só em `.trivyignore.yaml`. O aviso de `management_metrics_collection` deprecado no boot é esperado (ver `rabbitmq.conf`).
- Fluxo de mudança do template: `./scripts/render-definitions.sh` -> `docker compose restart rabbitmq` -> `docker compose run --rm provisioner`
  (sem o restart o import não roda). O provisionador só apaga usuários/policies dentro dos vhosts do template.
- TLS (T09): `docker-compose.tls.yml` + `./scripts/generate-certs.sh` + `./scripts/smoke-tls.sh` (AMQPS 5671 só em 127.0.0.1, TLS 1.2+, peer verificado; management 15672 segue sem TLS em dev; `certs/` gitignored).
- `scripts/smoke-edge.sh` cobre bordas (permissões, render, provisionador); mensagens e nomes de teste dos scripts em inglês.
- `scripts/e2e-graylog.sh`: e2e REAL broker -> Fluent Bit -> Graylog, **só local** (fora do CI: o runner não tem Graylog); não reinicia
  nada e exige `../graylog` no ar. Rode ao mudar `config/fluent-bit/`, o log do broker, as imagens ou o pipeline/alertas do RabbitMQ no
  Graylog. Verificador JSON em `tests/e2e/graylog_check.py` (imagem do smoke, sem rede).
