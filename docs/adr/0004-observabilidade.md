# ADR-0004: Observabilidade — Prometheus/Grafana e logs no Graylog com fallback

- **Status**: Aceito
- **Data**: 2026-11-19
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. IV.6, Art. VI.1 a VI.4, Art. VII

## Contexto

Constituição VI: logs estruturados no Graylog via GELF e health checks. O Grafana do workspace (`C:\Workspace\grafana`) tem Prometheus próprio
(`prometheus/`, rede interna `metrics`, alvos por `file_sd`, regras em `rules.yml`), dashboards por arquivo (`provisioning/dashboards/<projeto>/`,
`allowUiUpdates: false`) e alertas por arquivo (`provisioning/alerting/rules.yaml`, pasta e labels `project`/`severity`). O Graylog mapeia `tag` para
`service_name` (regra 10) e tem LGPD no pipeline. Requisito: se o Graylog cair, os logs do broker não podem se perder nem ficar sem verificação.
Este projeto não altera `grafana/` nem `graylog/`.

## Decisão

### Métricas
1. `rabbitmq_prometheus` na 15692 (publicada só em `127.0.0.1`), com `prometheus.return_per_object_metrics = true` (poucas filas em dev; a doc avisa para ambientes pequenos).
2. O broker cria a rede **interna** `rabbitmq-metrics` (nome fixo, sem saída externa). Participam o broker (scrape em 15692) e o `log-shipper` (scrape do backlog do coletor em 2020, usado pelo alerta de backlog); o `log-shipper-test` do smoke **não** entra nela (não precisa). Na fase seguinte o Prometheus do Grafana entra nela como `external` (mesmo padrão de `metrics`/`probe`). O broker não entra na `observability`.
3. Insumos para o `grafana/` (tarefa F01, **exige aprovação, fora do escopo atual**): job `rabbitmq` em `prometheus/prometheus.yml` (ou `targets/rabbitmq.yml`, `rabbitmq:15692`); rede `rabbitmq-metrics` em `prometheus/docker-compose.metrics.yml`; dashboards oficiais em `provisioning/dashboards/rabbitmq/` (JSON baixado da revisão fixa): **RabbitMQ-Overview id 10991 rev 15**, **Erlang-Distribution id 11352 rev 10**, **Erlang-Memory-Allocators id 11350 rev 8** (revisões de 2025-04-17 no grafana.com; revalidar ao implementar; datasource uid `prometheus`; passar no `lint-dashboards.sh`); alertas na pasta `rabbitmq` (labels `project: rabbitmq`, `severity`): fila crescendo, fila com mensagens e sem consumidor, memória > 80% do limite/alarme, disco perto do `disk_free_limit`, **DLQ não vazia** (`queue=~".*\.dlq"`), broker fora (`up`), backlog do coletor de logs; nomes exatos de métrica a confirmar na doc do plugin.

### Logs (comparação)
| Opção | Prós | Contras |
|---|---|---|
| **a) Arquivo JSON em volume + coletor Fluent Bit com buffer em disco e retry** | Nada se perde com Graylog fora; verificável localmente; reenvio automático | Mais um container; retenção local limitada pela rotação |
| b) Só log driver GELF do Docker | Simples (padrão do Grafana) | UDP, sem buffer: perde mensagens com Graylog fora; não verificável |
| c) Vector em vez de Fluent Bit | Também faz buffer em disco | MPL-2.0, mais pesado; sem ganho aqui |

**Decisão: (a)**. O driver GELF (b) não é usado.
1. RabbitMQ grava `log.file` em JSON no volume `rabbitmq-logs` (`log.file.formatter = json`, rotação por tamanho `log.file.rotation.size` + `count` + `compress`; tamanho e contagem definidos em T07, p.ex. 10 MiB x 5) e mantém `log.console` JSON para `docker logs`. Nível `info` (nunca debug por padrão: sem conteúdo de mensagens).
2. Serviço **`log-shipper`** (Fluent Bit 4.2.8, Apache-2.0, imagem distroless por tag+digest): `tail` do arquivo com `DB` de offsets, `storage.type filesystem` com `storage.path` em volume `fluentbit-buffer`, saída `gelf` em modo **tcp** para `graylog:12201` pela rede `observability` (só o shipper entra nela), `Retry_Limit no_limits`, `storage.total_limit_size` finito para o buffer não encher o disco. Campos mantidos: `time`, `level`, `msg` (lista final após amostra real) + `service_name=rabbitmq` e `tag=rabbitmq`, que o pipeline do Graylog já converte.
3. Verificação: `scripts/logs-fallback-check.sh` (logs retidos no arquivo local + estado do buffer pendente via `/api/v1/storage` e `/api/v1/metrics`, com `storage.metrics on` e `http_server`); vivacidade do coletor por **sonda externa** (`scripts/shipper-api.sh`; a imagem não tem shell e o compose **não** declara healthcheck, ver "Atualização"); métrica Prometheus do Fluent Bit para o alerta de backlog.
4. Teste no smoke **sem derrubar o Graylog real**: um `gelf-sink` de teste (profile `logs-test`, rede própria) substitui o destino via `GELF_HOST`; o smoke para o sink, gera eventos marcados, confirma o arquivo local e o backlog, religa o sink e confirma a chegada sem perda (duplicatas toleradas), inclusive após reiniciar o coletor com o sink parado (`tests/smoke/logs-fallback.sh`, seção n do smoke). **E2E com o Graylog real: apenas documentado** (comentário de `scripts/logs-fallback-check.sh`: pesquisar `service_name:rabbitmq` no Graylog com credenciais do operador); não existe script nem teste automatizado, e o CI não o executa.
5. LGPD (Art. IV.6): sem dados pessoais nos logs: só nomes de app/usuário técnico, vhost e nomes de fila. **Premissa registrada**: os usuários são técnicos (contas de serviço e `admin` do operador), não pessoas; por isso o nome de usuário que aparece nas linhas de falha de login (`failed to authenticate`) não é dado pessoal. Se um dia houver usuário-pessoa no broker, o filtro do coletor precisa mascarar esse campo (rever este item); filtro de campos no coletor; smoke confirma ausência da senha e de `Authorization`.
6. Graylog (tarefa F02, **exige aprovação, fora do escopo atual**, em `graylog/provisioning/provision.sh` e `rules/`): stream "RabbitMQ - Infra" por `service_name:rabbitmq`, retenção, regra de pipeline para normalizar `level` e manter só `level/logger/msg`, alertas (erros, `refused`/auth failures em rajada). Até lá os logs chegam ao stream padrão.

## Alternativas consideradas
Ver tabela acima; também descartado `log.exchange` (loga no próprio broker: circular e inútil com o broker fora).

## Consequências
- **Positivas**: sem perda com Graylog fora; verificável; métricas prontas para o Grafana.
- **Negativas / riscos**: arquivo local é a fonte: rotação limita a retenção (~50 MiB) e uma parada longa do coletor pode perder logs rotacionados e comprimidos que ele não lê; imagem distroless do coletor sem healthcheck no compose (sonda externa `scripts/shipper-api.sh`; a variante `-debug` com shell foi descartada por ter centenas de achados HIGH/CRITICAL); GELF TCP do Graylog não autentica o remetente (já registrado no `graylog/CLAUDE.md`).
- **Ações decorrentes**: T06, T07, T08 (implementadas); F01 e F02 dependem de aprovação em `grafana/` e `graylog/` (fora do escopo deste ADR e do código aqui).

## Atualização (rodada de correção da Onda 3, 2026-11-19)

1. **Imagem do coletor distroless**: trocada `fluent/fluent-bit:4.2.8-debug` (666 achados HIGH/CRITICAL no Trivy, 16 CRITICAL) por `fluent/fluent-bit:4.2.8` (tag + digest, build de 2026-08-04, última 4.2.x). Trivy HIGH/CRITICAL: 118 achados (1 CRITICAL, 59 com correção publicada no Debian mas ainda não na imagem; a maior parte é `libpq5`, plugin que não usamos). A 5.x existe, mas é major e a mais recente tem menos de duas semanas: fica para decisão própria.
2. **Healthcheck sem shell**: a imagem não tem shell nem `curl`, então o compose **não** declara healthcheck para o coletor (o `restart: unless-stopped` cobre queda do processo). A sonda é externa e honesta: `scripts/shipper-api.sh` sobe um container descartável que compartilha a rede do coletor (`--network container:`) e consulta a API de `127.0.0.1:2020` com o `bash` da imagem do broker (sem pull nem imagem nova). Smokes, `logs-fallback-check.sh` e o smoke do fallback usam essa sonda; vivacidade = a API responde `/api/v1/uptime` (continua sem usar `/api/v1/health`, que reprova com o Graylog fora). A config é conferida com `docker cp`.
3. **Gate no CI** (`.github/workflows/ci.yml`, job `images`): no coletor, **CRITICAL com correção disponível bloqueia** (`--ignore-unfixed --exit-code 1`); **HIGH é informativo** (`--exit-code 0`) até a imagem oficial ser reconstruída; no broker, HIGH/CRITICAL com correção bloqueiam. A única exceção, **`CVE-2026-111497`** (`libbrotli1`, sem caminho alcançável: o coletor não faz HTTP), está em `.trivyignore.yaml` com justificativa e **validade 2026-12-31; reavaliar** ao trocar a imagem do coletor ou até essa data. **O TLS não entra no CI**: `docker-compose.tls.yml` só tem a sintaxe validada (`config -q`); o `scripts/smoke-tls.sh` roda localmente.
4. **Nível GELF**: `config/fluent-bit/level.lua` (filtro `lua`) converte `level` para o número syslog (error=3, warning=4, notice=5, info=6 ...), porque `"error"` chegava como texto. Coberto por `tests/smoke/logs-fallback.sh`.
5. **Alerta de descarte**: `fluentbit_output_dropped_records_total` sobe quando o teto do buffer (`storage.total_limit_size`) descarta registros (confirmado pelo QA); o alerta "Coletor descartando registros" permanece.
