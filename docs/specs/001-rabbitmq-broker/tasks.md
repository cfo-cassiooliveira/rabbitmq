# Tarefas — Spec 001 Broker RabbitMQ 4.x

Responsável de todas: `backend-developer` (infra Docker), salvo revisão/QA. Um repositório e um desenvolvedor: tarefas que tocam os mesmos arquivos ficam em sequência na mesma instância. Nenhum git/repositório é criado antes de T12.
O smoke test é incremental: cada tarefa adiciona suas verificações a `scripts/smoke-test.sh` (Art. V.1). Nenhuma tarefa altera `grafana/`, `graylog/`, `keycloak/` ou outros projetos.

## Plano de ondas (revisado)

| Onda | Tarefas | Observação |
|---|---|---|
| 1 | T01 → T02 → T03 → T04 | Mesma instância, sequência (todas tocam compose/config). Revisão + QA ao fim |
| 2 | T05 | Smoke AMQP ponta a ponta. Revisão + QA |
| 3 | T06 → T07 → T08 | Mesma instância (compose, `rabbitmq.conf`, smoke). Métricas, logs com fallback, teste do fallback. Revisão + QA |
| 4 | T09 (opcional, depende da pergunta 2) | TLS |
| 5 | T10, T11 | Arquivos distintos (CI x docs); só em paralelo com worktree, recomendado sequencial |
| 6 | T12 | Exige autorização (git, GitHub, `_templates/`) |

Pós-aprovação, fora do escopo atual: F01 (grafana), F02 (graylog), F03 (apps).

## T01 — Scaffold do projeto
- Depende de: aprovação do plano. Arquivos: `.gitignore` (`.env`, `definitions/definitions.json`, `certs/`), `.gitattributes` (`* text=auto eol=lf`), `CLAUDE.md` (de `_templates/project-CLAUDE.md`), `README.md` (esqueleto), `SECURITY.md`.
- Testes: `git check-ignore` dos segredos (antes de T12, com `git init` descartável no scratch) e verificação de LF no CI. Pronto: estrutura criada, `CLAUDE.md` < 150 linhas.

## T02 — Compose base, config e rede
- Depende de: T01. Arquivos: `docker-compose.yml`, `config/rabbitmq.conf`, `config/enabled_plugins`, `scripts/generate-env.sh`, `scripts/messaging-network.sh`, `scripts/smoke-test.sh` (seção a).
- Escopo: imagem tag+digest, `mem_limit: 1g`, healthcheck, volume nomeado, portas em `127.0.0.1`, plugins, watermark absoluto e `disk_free_limit`, `.env` com `openssl`, `${VAR:?...}`.
- Testes: smoke (a): healthy, UI/API 200 com admin, portas só em loopback. Pronto: `docker compose config -q` ok, broker healthy, smoke (a) verde.

## T03 — Definitions versionadas e render
- Depende de: T02. Arquivos: `definitions/definitions.template.json`, `scripts/render-definitions.sh`, `config/rabbitmq.conf` (import), compose (montagem somente leitura), smoke (b parcial, e parcial).
- Escopo: vhost `dev`, usuários admin e smoke-app com hash, permissões por prefixo, policies DLX, topologia de smoke; confirmar na doc `default_queue_type`, dead-lettering at-least-once e `password_hash`.
- Testes: `GET /api/definitions` contém a topologia; reinício sem erro. Pronto: ADR-0002 aceito pelo usuário.

## T04 — Provisionador idempotente e remoção do guest
- Depende de: T03. Arquivos: `provisioning/Dockerfile`, `provisioning/provision.sh`, compose (serviço `provisioner`, `service_healthy`), smoke (guest, idempotência).
- Escopo: aguardar API, `DELETE /api/users/guest`, remover itens obsoletos, validar contagens. Reexecutável.
- Testes: guest negado por AMQP e HTTP; provisionador 2x com definitions normalizadas iguais. Pronto: ADR-0003 revisado.

## T05 — Smoke ponta a ponta AMQP (pika)
- Depende de: T04. Arquivos: `tests/smoke/Dockerfile`, `tests/smoke/smoke.py`, `tests/smoke/requirements.txt` (pin), compose (profile `smoke`), `scripts/smoke-test.sh`.
- Escopo: publish com confirm+mandatory, quorum (verificado pela API), consume/ack manual, nack requeue=false → DLQ, basic.return sem rota, permissões negadas fora do prefixo. Limpa o que cria.
- Pronto: `./scripts/smoke-test.sh` verde duas vezes seguidas.

## T06 — Métricas Prometheus e insumos do Grafana
- Depende de: T05. Arquivos: `config/rabbitmq.conf` (`prometheus.return_per_object_metrics`), compose (rede interna `rabbitmq-metrics`, porta 15692 em loopback), smoke (c metrics), `docs/integration/grafana-inputs.md` (alvo e rede, dashboards 10991 rev 15 / 11352 rev 10 / 11350 rev 8 com JSON baixado por revisão, regras de alerta com expressões PromQL, tarefa F01).
- Escopo: confirmar na doc do plugin os nomes de métricas (fila, consumidores, memória, disco, DLQ). Nada é escrito em `grafana/`.
- Testes: smoke: `/metrics` responde e contém métricas de fila e memória; rede `rabbitmq-metrics` é `internal`. Pronto: documento com PromQL validado contra o broker de pé (consulta direta ao `/metrics`).

## T07 — Logs: arquivo + rotação + coletor Fluent Bit + verificação
- Depende de: T06. Arquivos: `config/rabbitmq.conf` (`log.file.*` JSON, `log.file.rotation.size/count/compress`, nível info, console JSON), `config/fluent-bit/fluent-bit.conf` (+ parsers), compose (serviço `log-shipper`, volumes `rabbitmq-logs` e `fluentbit-buffer`, rede `observability` só no shipper, `mem_limit`, `GELF_HOST` parametrizável), `scripts/logs-fallback-check.sh`, `.env` (variáveis do destino).
- Escopo: confirmar na doc: chaves `log.file`, rotação, formato JSON, campos reais (amostra); Fluent Bit: `tail`+`DB`, `storage.type filesystem`, `storage.total_limit_size`, saída `gelf` tcp, `Retry_Limit`, `http_server`/`storage.metrics`, healthcheck (imagem distroless? decidir variante). Campos finais: `time`, `level`, `msg`, `service_name=rabbitmq`, `tag=rabbitmq`.
- Testes: smoke: arquivo JSON existe e rotação configurada; `logs-fallback-check.sh` lista logs locais e buffer; shipper healthy; log sem senha. Pronto: ADR-0004 aceito pelo usuário.

## T08 — Smoke do fallback de logs (Graylog fora)
- Depende de: T07. Arquivos: `tests/smoke/gelf-sink.py` (ou `docker-compose.logs-test.yml` com sink), `tests/smoke/logs-fallback.sh`, `scripts/smoke-test.sh`.
- Cenário: (1) sink no ar, evento marcado chega ao sink e ao arquivo; (2) sink parado, N eventos marcados: arquivo registra e `logs-fallback-check.sh` mostra backlog > 0; (3) reiniciar o shipper com o sink parado; (4) sink religado: todos os N marcadores chegam (duplicatas toleradas). Não derruba o Graylog real. E2E opcional contra o Graylog real: `logs-fallback-check.sh --graylog` com URL/credenciais por variável de ambiente.
- Pronto: teste verde duas vezes seguidas e limpando o que cria.

## T09 — TLS opcional (profile `tls`) [depende da pergunta 2]
- Depende de: T05. Arquivos: `scripts/generate-certs.sh`, `config/tls.conf`, compose, smoke AMQPS 5671 com verificação de peer.
- Pronto: smoke AMQPS verde; plain continua no profile padrão.
- **Concluída (2026-11-19)**: `docker-compose.tls.yml` (complemento: o broker não muda por profile, então o TLS é um segundo arquivo do compose; o cliente `smoke-tls` fica no profile `tls`), `config/tls.conf`, `scripts/generate-certs.sh`, `scripts/smoke-tls.sh` e fase `tls` do `tests/smoke/smoke.py`. Fora do CI (chave 0600 do host ilegível ao usuário do container no runner Linux).

## T10 — CI
- Depende de: T08 (e T09 se feito). Arquivos: `.github/workflows/ci.yml` (shellcheck, gitleaks, trivy misconfig, smoke incluindo fallback de logs; imagens por digest, modelo do graylog).
- Pronto: workflow válido e passos equivalentes rodados localmente.

## T11 — Documentação final
- Depende de: T08. Arquivos: `README.md`, `CLAUDE.md`, `docs/INDEX.md`, `summary.md` (estado), `scripts/backup-definitions.sh`, procedimento `add-app` (usuário, prefixo, policy DLX), seção "Próxima fase" (insumos da spec §7, F01 a F03).
- Testes: seguir o README do zero em cópia limpa. Pronto: comandos do README executados.

## T12 — Repositório e entrega (exige autorização)
- Depende de: T10, T11, revisão final. Ações: `git init`, `master` e `DEV-001`, commits Conventional Commits sem co-autoria de IA, linha `cfo-cassiooliveira/rabbitmq public` em `C:\Workspace\_templates\github-repos.conf` (fora desta pasta), `github-repo-setup.sh apply/check`, PR de `DEV-001`. Nada é executado sem pedido do usuário.

## Fora do escopo atual (exigem aprovação)
- **F01 (grafana/)**: `prometheus/prometheus.yml` ou `targets/rabbitmq.yml` (job `rabbitmq:15692`), rede `rabbitmq-metrics` externa em `prometheus/docker-compose.metrics.yml`, dashboards em `provisioning/dashboards/rabbitmq/`, alertas em `provisioning/alerting/rules.yaml` (pasta `rabbitmq`: fila crescendo, sem consumidor, memória/disco, DLQ não vazia, broker fora, backlog do coletor), execução do `lint-dashboards.sh` e do smoke do Grafana.
- **F02 (graylog/)**: em `provisioning/provision.sh`/`rules/`: stream "RabbitMQ - Infra" (`service_name:rabbitmq`), retenção, regra de pipeline (`level`, só `level/logger/msg`), alertas e caso no `smoke-test.sh` do Graylog.
- **F03 (apps)**: usuário e topologia por app (cadastro, legado, keycloak), conexão pela rede `workspace-messaging`.

## Revisão e QA
Ao fim de cada onda: `code-reviewer` e `qa-engineer` (smoke repetido, gitleaks, `docker compose config`). Até 2 rodadas de correção.
