# RabbitMQ — broker local

RabbitMQ 4.3 (single-node) em Docker para os projetos do workspace, com topologia, usuários e permissões como código,
métricas Prometheus e logs com fallback local. Índice de decisões e specs: [docs/INDEX.md](docs/INDEX.md).

## Destaques técnicos

- [Topologia como código](definitions/definitions.template.json) e [render](scripts/render-definitions.sh): mudança revisável por diff, sem senha nem hash no git.
- [Provisionador idempotente](provisioning/provision.sh): o import do RabbitMQ só acrescenta, e usuários ou policies obsoletos ficariam no broker.
- [DLQ e retry com espera](config/rabbitmq.conf): mensagem com defeito sai da fila principal e falha transitória volta após 30 s.
- [Permissões por app](docs/adr/0003-seguranca-usuarios-tls-segredos.md): a credencial de um app não alcança as filas de outro serviço.
- [Logs com buffer em disco](config/fluent-bit/fluent-bit.conf): Graylog fora não interrompe a coleta (dentro do teto do buffer e da rotação).
- [CI com broker real](.github/workflows/ci.yml): permissões, retry, DLQ e TLS são exercitados, não só validados por lint.

## Uso de IA

Este projeto foi desenvolvido com auxílio de IA (**Claude Code**), na implementação e em code review. As decisões de
arquitetura estão registradas nas ADRs, e as mudanças passam por testes automatizados e CI antes de entrar na `master`.

## Requisitos do host

Docker Desktop (Compose v2), bash (Git Bash no Windows), `openssl`, `xxd` e `curl`. Memória livre: 1 GiB para o broker.
Em Windows/WSL2 os volumes são nomeados (não use bind mount de dados) e os scripts precisam de fim de linha LF (`.gitattributes`).

## Subir do zero

```bash
./scripts/generate-env.sh            # .env (0600, segredos aleatórios, nunca versionado) + definitions/definitions.json
./scripts/observability-network.sh   # rede externa "observability" (o Graylog pode estar fora do ar)
docker compose up -d --build         # broker (healthy), provisionador e coletor de logs
./scripts/smoke-test.sh              # verificação ponta a ponta (~3 min, inclui o fallback de logs)
```

`generate-env.sh` não sobrescreve um `.env` existente. `SKIP_LOGS_FALLBACK=1 ./scripts/smoke-test.sh` pula o trecho de ~2 min do fallback;
`./scripts/smoke-edge.sh` cobre bordas (permissões, render, provisionador).

## Portas e redes

| Item | Valor |
|---|---|
| AMQP | `127.0.0.1:5672` (host) ou `rabbitmq:5672` pela rede `workspace-messaging` (vhost `dev`) |
| UI/API de management | http://localhost:15672 (usuário `admin`, senha `RABBITMQ_ADMIN_PASSWORD` do `.env`) |
| Métricas Prometheus | `127.0.0.1:15692/metrics`; rede `rabbitmq-metrics` para o Prometheus |
| AMQPS (TLS) | `127.0.0.1:5671`, opcional (complemento `docker-compose.tls.yml`, ver seção TLS e ADR-0003) |
| `workspace-messaging` | criada pelo compose deste projeto; os apps a usam com `external: true` |
| `observability` | externa, criada por `scripts/observability-network.sh` (só o coletor de logs entra) |
| `rabbitmq-internal`, `rabbitmq-metrics` | internas |

Todas as portas publicam apenas em `127.0.0.1`; EPMD/distribuição não são publicados.

## Mudando a topologia, usuários ou permissões

O `definitions/definitions.template.json` é a fonte de verdade (a UI não é). Fluxo:

```bash
./scripts/render-definitions.sh          # regenera definitions/definitions.json (novo sal nos hashes)
docker compose restart rabbitmq          # o import só ocorre no boot e quando o arquivo mudou (skip_if_unchanged)
docker compose run --rm provisioner      # remove obsoletos e valida (idempotente)
```

O import é aditivo; remoções ficam com o provisionador, que só apaga usuários e policies dos vhosts do template
(usuários com permissão em vhost fora do template, filas e exchanges não são apagados). Adicionar uma app:
[docs/integration/add-app.md](docs/integration/add-app.md).

## Logs e fallback

O broker grava `rabbit.log` (JSON, rotação 10 MiB x 5) no volume `rabbitmq-logs` e mantém o console. O coletor `log-shipper`
(Fluent Bit, imagem distroless) reenvia ao Graylog (GELF TCP `graylog:12201`, rede `observability`) com buffer em disco e retry sem limite: com o
Graylog fora, o coletor continua de pé e retém. `./scripts/logs-fallback-check.sh` mostra os logs locais e o backlog.
`./tests/smoke/logs-fallback.sh` prova o fallback com um `gelf-sink` descartável (não toca o Graylog real).
Como a imagem do coletor não tem shell, sua API interna é consultada de fora por `./scripts/shipper-api.sh` (ADR-0004).

**E2E real com o Graylog (só local)**: `./scripts/e2e-graylog.sh` gera logins recusados reais (management e AMQP, usuários
fictícios `e2e-nobody-<run>-*`) sem reiniciar nada e confere na API de busca do Graylog o stream `RabbitMQ - Infra` (e nenhum outro),
`service_name=rabbitmq`, nível 3/4, o texto real e as consultas dos alertas. Requer o broker, o coletor e o `../graylog` no ar
(senha lida de `../graylog/.env`, nunca impressa); falha clara se o Graylog estiver fora. Não roda no CI (o runner não tem Graylog).
Rode ao mudar o coletor, o log do broker, a imagem ou o pipeline/alertas do RabbitMQ no Graylog (ADR-0004, Atualização DEV-004).

## Observabilidade

Métricas em `15692` (plugin `rabbitmq_prometheus`); insumos para dashboards e alertas do Grafana em
[docs/integration/grafana-inputs.md](docs/integration/grafana-inputs.md). O aviso de `management_metrics_collection`
deprecado no boot é esperado (ver `config/rabbitmq.conf`).

## Backup

`./scripts/backup-definitions.sh [pasta]` exporta as definitions (com hashes de senha) para `backups/` (gitignored, modo 0600).
Mensagens e dados dos volumes não entram; `docker compose down -v` apaga os volumes.

## TLS opcional (AMQPS)

O texto plano (5672) continua sendo o padrão em dev. Para testar AMQPS com verificação de peer:

```bash
./scripts/generate-certs.sh          # CA local + certificado do servidor em certs/ (gitignored; chaves 0600)
./scripts/smoke-tls.sh               # sobe o broker com TLS, roda o cliente pika e volta ao modo padrão (KEEP_TLS=1 mantém)
# manualmente: docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate --no-deps rabbitmq
```

O listener 5671 (só em `127.0.0.1`) aceita TLS 1.3 e 1.2, sem cifras fracas (`config/tls.conf`); os clientes devem confiar em `certs/ca.pem`
e validar o nome (`rabbitmq`, `localhost` ou `127.0.0.1`). A **UI de management (15672) continua sem TLS em dev** (só em loopback; o smoke confere).
A chave da CA (`ca.key`) nunca é montada no container. Fora de dev o TLS é obrigatório (ADR futuro).

## Troubleshooting

| Sintoma | Causa provável / ação |
|---|---|
| `network observability declared as external, but could not be found` | rode `./scripts/observability-network.sh` antes do `up` |
| Mudei o template e nada mudou no broker | falta o `docker compose restart rabbitmq` (o import só roda no boot com arquivo alterado) |
| Login recusado na UI/AMQP | `guest` não existe; use `admin` e a senha do `.env`; apps usam o seu usuário |
| `port is already allocated` | outro processo usa 5672/15672/15692; pare-o (as portas não mudam) |
| Broker reinicia por memória | `mem_limit` 1g e watermark de 600 MiB; veja `docker compose logs rabbitmq` |
| Sem logs no Graylog | esperado se o Graylog está fora: `./scripts/logs-fallback-check.sh`; o coletor entrega quando ele voltar |
| Script falha com `\r` | fim de linha CRLF; confira o `.gitattributes` e refaça o checkout |

## CI

`.github/workflows/ci.yml` (actions fixadas por SHA, imagens por digest, `permissions: contents: read`): ShellCheck, gitleaks
(histórico), Trivy `fs` e `image`, `docker compose config` e o smoke completo (`smoke-test.sh`, `smoke-edge.sh`) com `.env` gerado no job
e sem Graylog real. Exceções de varredura: `.gitleaks.toml` (routing key de teste, falso positivo) e `.trivyignore.yaml` (uma por achado, com justificativa e validade). O Trivy da imagem do coletor bloqueia CRITICAL com correção disponível. O smoke TLS (`smoke-tls.sh`) roda no job `smoke-tls`: em Linux o `generate-certs.sh` mantém a `server.key` em 0600 e a entrega ao usuário `rabbitmq` (uid 999) do container, porque o bind mount preserva o dono (ADR-0003).

## Próxima fase

O broker já entrega a rede `workspace-messaging`, host `rabbitmq`, vhost `dev` e as métricas/logs. Fora deste projeto, com aprovação:

- **F01 (grafana)**: alvo `rabbitmq:15692` por `file_sd`, rede `rabbitmq-metrics` externa, dashboards 10991/11352/11350 revisados e alertas
  (fila crescendo, sem consumidor, memória/disco, DLQ não vazia, broker fora, backlog do coletor).
- **F02 (graylog)**: stream "RabbitMQ - Infra" (`service_name:rabbitmq`), retenção, regra de pipeline e alertas.
- **F03 (apps: cadastro, legado, keycloak)**: cada app ganha usuário/prefixo/policy DLX por [add-app](docs/integration/add-app.md), entra na rede
  `workspace-messaging` (`external: true`), conecta em `rabbitmq:5672` vhost `dev` e guarda a senha no seu próprio `.env`/cofre.

Segurança: [SECURITY.md](SECURITY.md).
