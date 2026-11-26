# Tarefas — Spec 002 Importação em lote 1x1

Status: **Aceito** (2026-11-25); MVP até **04/12/2026**. Onda 0 concluída (decisões na spec §8). Toda tarefa inclui os testes que a cobrem na mesma entrega (Art. V.1). Cada repositório trabalha em branch `DEV-NNN` própria, criada da `master` (ADR-0001 do rabbitmq). Commit só a pedido.

## Onda 0 — Aprovação
- [x] **A1** Perguntas respondidas (spec §8); spec, plano e ADRs 0005/0006 aceitos em 2026-11-25.
- [ ] **A2** Spike: publicar e consumir 1 mensagem com `cadastro-app` (sem código de produção).

## Onda 1 — Fundações (repositórios distintos, paralelizáveis)
- [x] **R1** [rabbitmq] `cadastro-app` com permissões exatas no `definitions.template.json`; `generate-env.sh` e `render-definitions.sh` aceitam a senha. *Teste*: smoke seção **o** (permissões: recusa fora do prefixo, `configure` negado).
- [x] **R2** [rabbitmq] Exchanges `cadastro.events`, `cadastro.retry`, `cadastro.dlx`; filas `cadastro.user-import-lines`, `.retry`, `.dlq` (quorum); bindings.
- [x] **R3** [rabbitmq] Policies (DLX at-least-once + `reject-publish`; retry TTL 30 s). *Teste*: smoke prova retry após nack e DLQ após esgotar; `smoke-edge.sh` cobre a renderização. Atualizar `docs/integration/add-app.md` e `docs/INDEX.md`.
- [ ] **L1** [legado] SQL Server na rede `workspace-data` por override de compose. *Teste*: conexão a partir de container na rede.
- [ ] **L2** [legado] Chave HMAC do Cadastro restrita a consulta e marcação; `legacy_app` com DENY no esquema `import`. *Teste*: integração (Testcontainers) cobrindo 200 nas rotas permitidas e 403 em `credential-verifications`.
- [ ] **K0** [Keycloak] Client `cadastro-importer` (menor privilégio), role `user-importer`, atributo `importLineId`, SMTP Mailpit. *Teste*: smoke do realm.
- [ ] **C1** [cadastro] Esquema `import` (migrations por `cadastro_migrator`, runtime `cadastro_app`), entidades Lote/Linha, cifra dos dados pessoais, ADR-0007. *Teste*: unitários de domínio e integração das migrations.

## Onda 2 — Entrada (sequência no `cadastro`)
- [x] **C2** Upload `POST /api/v1/user-imports`: ClamAV fail-closed, validação em streaming (cabeçalho, 5 MB, 5.000 linhas, e-mail, CPF, duplicados), extrator CSV atrás de `IExtratorDeUsuarios`. *Teste*: tabela de arquivos válidos e inválidos; ClamAV indisponível recusa.
- [x] **C3** Lote em `AwaitingConfirmation`, resumo e confirmação em 2 passos; autorização `user-importer` + OTP; auditoria do acesso negado. *Teste*: 401/403/200.
- [x] **C3b** Consulta de lotes e linhas (query com `AsNoTracking`, DTO sem dados sensíveis). Inclui o caso de uso de reprocessar (`ImportBatch.Reprocess`, já modelado na C1; grava a auditoria na mesma transação) e o de cancelar lote (`Cancel(lines, now)` apaga os dados das linhas pendentes).
- [x] **C4** Confirmação grava 1 linha de outbox por pessoa na mesma transação; relay publica com confirms e `mandatory`; envelope com `traceparent`. *Teste*: integração com RabbitMQ real; broker parado não perde linha.
  - Nota (C4/C5): o `cadastro-app` não tem configure no broker; o código não pode chamar QueueDeclare/ExchangeDeclare ativos (só passivo ou nenhum), pois a topologia vem do definitions.

## Onda 3 — Processamento
- [x] **K1/C5a** Consumidor (prefetch 10, ack manual) cria o usuário no Keycloak via `cadastro-importer`, sem senha, `UPDATE_PASSWORD`, e-mail de ativação 72 h, limite de 10/s; já existente é pulado. **Chame `execute-actions-email` sempre com `?lifespan=259200`** (o realm voltou ao padrão de 12 h; só o Cadastro pede 72 h) e use só criação de usuário e e-mail de ativação (`manage-users` permite mais, risco aceito). O `cadastro-app` do broker não declara topologia (sem configure). *Teste*: integração com Keycloak real.
- [x] **C5b** Inbox por `messageId` na mesma transação do efeito; retry por TTL (30 s, até 5 ciclos); DLQ; apagar dados pessoais ao fim da linha. *Teste*: mensagem duplicada, falha transitória, falha definitiva.
- [x] **C5c** Marcação no Legado (candidato único com e-mail exato; timeout, retry, circuit breaker; falha não desfaz o Keycloak; `LegacyMarkStatus`). *Teste*: 0, 1 e vários candidatos; API fora do ar.
- [x] **F1** Telas Angular: envio, resumo, confirmar, lista, detalhe, reprocessar, relatório; aviso de conclusão (Q2). *Teste*: Vitest + Playwright com screenshots mobile/tablet/desktop e axe.

## Onda 4 — Fechamento do MVP
- [x] **E1** E2E com 5.000 linhas: sem perda, sem duplicidade, reenvio do mesmo arquivo, varredura de logs sem CPF/e-mail. Quality Gate do SonarQube aprovado. Concluída em 2026-11-25: E2E real 11/11 (relatório em `e2e-report.md`); gate aprovado no `cadastro` (cobertura 93,1%) e no `legado-cadastro-usuarios` (94,4%). O `Keycloak` não teve gate rodado: a entrega só altera JSON de realm, shell, compose e docs, que o SonarQube não analisa. Não verificado na stack real: auditoria do 403, broker fora do ar na publicação, esgotamento dos 5 ciclos, `AlreadyExists`, ambiguidade e Legado indisponível (cobertos por testes de integração).
  - Status (2026-11-26): E2E real **passou** (11/11, 5.000 linhas, 4.950 criadas sem perda nem duplicata, 409 no reenvio, idempotência, retry/DLQ, zero dado do CSV em logs e payloads AMQP); `cadastro/scripts/e2e-import.sh`, relatório em [e2e-report.md](e2e-report.md). **Falta**: Quality Gate do SonarQube (não executado). Por isso a tarefa segue aberta.
- [ ] **J1** (obrigatória antes de produção; no MVP local pode ficar documentada) Job de limpeza por retenção no Cadastro: relatório 90 dias, auditoria 12 meses e dados cifrados de linhas com erro vencidas (spec §8 Q9; campos `ReportExpiresAtUtc`/`ExpiresAtUtc` já indexados na C1). *Teste*: integração com SQL Server real.
- [x] **D1** README da importação (diagrama, como rodar, CSV de exemplo com linhas inválidas, GIF curto); atualizar o card do projeto no site principal.
- [ ] **O1** (fora do MVP, spec §8 Q1) Painel do lote/fila no Grafana, alerta de DLQ não vazia, stream no Graylog.

## Depois do MVP
- [ ] XLSX e PDF com layout fixo (novos `IExtratorDeUsuarios`).
- [ ] ADR-0008: evento `identity.user.migrated.v1` consumido pelo Legado.
- [ ] Keycloak: claims customizados e login social.
