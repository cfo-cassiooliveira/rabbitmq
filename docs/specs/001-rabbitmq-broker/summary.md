# Spec 001 — Broker RabbitMQ (resumo)

**Status:** Aceita (2026-11-19); ADRs 0001–0004 Aceitos. Implementada até T11; T12 (repositório e entrega) não concluída. F01/F02/F03 fora do escopo.
Detalhes: [spec](spec.md) · [plan](plan.md) · [tasks](tasks.md) · ADRs 0001–0004 em `../../adr/`.

## Objetivo
Criar e configurar o RabbitMQ 4.x local (single-node, Docker) com segurança, observabilidade no Grafana e logs no
Graylog com fallback verificável. O uso pelos demais projetos fica para a fase seguinte.

## Decisões-chave
- Imagem oficial `rabbitmq:4.3-management` (tag + digest), volumes nomeados, `mem_limit` 1g, healthcheck (ADR-0001).
- Topologia por `definitions.template.json` versionado, sem segredos; vhost `dev`, quorum queues, DLX/DLQ (ADR-0002).
- `guest` removido; usuários `admin` e `smoke-app` com permissões mínimas; segredos só no `.env`; TLS opcional (ADR-0003).
- Métricas Prometheus em 15692 para o Grafana; dashboards 10991/11352/11350 e alertas na tarefa F01 (ADR-0004).
- Logs: `log.file` JSON + Fluent Bit (buffer em disco, retry) → GELF `graylog:12201`; arquivo local sempre verificável
  por `scripts/logs-fallback-check.sh`; smoke com `gelf-sink` de teste.

## Interfaces entregues
Rede `workspace-messaging`, host `rabbitmq`, portas em 127.0.0.1: 5672, 15672, 15692, 5671 (profile `tls`).

## Perguntas (recomendação padrão)
1. Single-node ou cluster? (single-node)  2. TLS em dev? (opcional, T09)  3. Vhosts/apps iniciais? (`dev`, `admin`, `smoke-app`)
4. UI de management local ou Keycloak? (local agora)  5. Rede interna `rabbitmq-metrics` para o Prometheus? (sim)
6. Smoke com `gelf-sink`, E2E com Graylog real opcional? (sim)  7. Retenção local do log? (10 MiB x 5)
8. Backup? (export de definitions)  9. Editar `_templates/github-repos.conf` na T12? (sim)  10. F01/F02 após a T08? (sim)

## Riscos
Licenças (só imagem oficial; Fluent Bit Apache-2.0); imagem distroless do coletor
(healthcheck feito por sonda externa, ADR-0004); retenção limitada pela rotação; GELF sem autenticação; WSL2 (volumes nomeados, LF); memória;
segredos (`.env` 0600, gitleaks/trivy no CI).

## Estado das tarefas
T01–T04: concluídas e corrigidas na rodada 1 de revisão/QA (2026-11-18; imagem `rabbitmq:4.3-management`, RabbitMQ 4.3.8, digest fixado no compose; smoke seções a, b, c, e verdes).
T05: concluída (smoke AMQP com pika 1.3.2 em container descartável, seção (d) do smoke-test.sh; smoke verde 2x seguidas).
T06 (métricas Prometheus 15692, rede `rabbitmq-metrics`, `docs/integration/grafana-inputs.md`), T07 (log JSON + `log-shipper` Fluent Bit 4.2.8 distroless + `logs-fallback-check.sh`) e T08 (`tests/smoke/logs-fallback.sh` com `gelf-sink`): implementadas (2026-11-18), aguardando revisão/QA da Onda 3. T10 e T11 implementadas (aguardam revisão); T09 (TLS opcional) implementada em 2026-11-19 (complemento `docker-compose.tls.yml`, `generate-certs.sh`, `smoke-tls.sh`); T12 não iniciada. Rodada de correção da Onda 3 aplicada (nível GELF numérico, coletor distroless com sonda externa, gate Trivy, SC2164). Fora do escopo: F01 (grafana), F02 (graylog), F03 (apps).
