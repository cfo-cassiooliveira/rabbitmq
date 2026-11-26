# Índice — rabbitmq (leia este antes dos docs longos)

## Specs
- 002 Importação em lote 1x1 (usos do broker: usuário `cadastro-app`, exchanges, filas, policies; tarefas R1-R3 neste repositório) — `docs/specs/002-uso-pelos-projetos/{spec,plan,tasks}.md`
- 001 Broker RabbitMQ 4.x local (single-node, Docker, métricas e logs com fallback) — Aceita; implementada até T11, T12 pendente — `docs/specs/001-rabbitmq-broker/summary.md`

## ADRs (0001-0004 Aceitos em 2026-11-19; 0005-0006 em 2026-11-25)
- 0001 Imagem `rabbitmq:4.x-management` e execução single-node — `docs/adr/0001-imagem-e-modo-de-execucao.md`
- 0002 Topologia, nomenclatura e definitions + provisionador — `docs/adr/0002-topologia-e-definitions.md`
- 0003 Segurança: usuários, permissões, TLS, segredos — `docs/adr/0003-seguranca-usuarios-tls-segredos.md`
- 0004 Observabilidade: Prometheus/Grafana e logs no Graylog com fallback (Fluent Bit) — `docs/adr/0004-observabilidade.md`
- 0005 Importação 1x1 com Outbox + relay (spec 002) — `docs/adr/0005-importacao-1x1-outbox-relay.md`
- 0006 Usuário importado já migrado, sem senha (spec 002) — `docs/adr/0006-usuario-importado-ja-migrado-sem-senha.md`

## Comandos
- `./scripts/messaging-network.sh` cria a rede externa `workspace-messaging`
- `./scripts/generate-env.sh` cria o .env (nunca versionado)
- `docker compose up -d --build` sobe broker, provisionador e coletor de logs
- `./scripts/smoke-test.sh` teste ponta a ponta (confirm, quorum, ack, DLQ, guest, permissões, health, métricas, fallback de logs, cadastro-app: permissões, retry e DLQ)
- `./scripts/logs-fallback-check.sh` logs retidos localmente e backlog do coletor
- `./scripts/e2e-graylog.sh` e2e real broker -> Fluent Bit -> Graylog (só local, fora do CI; exige `../graylog` no ar)
- `./scripts/backup-definitions.sh` exporta as definitions (backups/, fora do git)
- `./scripts/smoke-edge.sh` bordas; `./scripts/generate-certs.sh` + `./scripts/smoke-tls.sh` TLS opcional (AMQPS); `./scripts/shipper-api.sh` API do coletor; CI em `.github/workflows/ci.yml`

## Onde procurar
- Plano e tarefas: `docs/specs/001-rabbitmq-broker/{spec,plan,tasks}.md` (ondas e tarefas F01/F02 pós-aprovação em `tasks.md`)
- Insumos para o Grafana: `docs/integration/grafana-inputs.md` (T06); adicionar app: `docs/integration/add-app.md`
- Convenções de mensageria dos serviços: `C:\Workspace\.claude\rules\messaging-rabbitmq.md`
