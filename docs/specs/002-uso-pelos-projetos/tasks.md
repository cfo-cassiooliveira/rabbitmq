# Tarefas — Spec 002 Importação em lote 1x1

Status: **Aceito** (2026-11-25); MVP até **04/12/2026**. Onda 0 concluída (decisões na spec §8). Toda tarefa inclui os testes que a cobrem na mesma entrega (Art. V.1). Cada repositório trabalha em branch `DEV-NNN` própria, criada da `master` (ADR-0001 do rabbitmq). Commit só a pedido.

## Onda 0 — Aprovação
- [x] **A1** Perguntas respondidas (spec §8); spec, plano e ADRs 0005/0006 aceitos em 2026-11-25.
- [x] **A2** Spike: publicar e consumir 1 mensagem com `cadastro-app` (sem código de produção). Feito (sem spike separado: o `cadastro-app` é exercitado pela seção **o** do smoke e pela implementação; conferido em 2026-11-27).

## Onda 1 — Fundações (repositórios distintos, paralelizáveis)
- [x] **R1** [rabbitmq] `cadastro-app` com permissões exatas no `definitions.template.json`; `generate-env.sh` e `render-definitions.sh` aceitam a senha. *Teste*: smoke seção **o** (permissões: recusa fora do prefixo, `configure` negado).
- [x] **R2** [rabbitmq] Exchanges `cadastro.events`, `cadastro.retry`, `cadastro.dlx`; filas `cadastro.user-import-lines`, `.retry`, `.dlq` (quorum); bindings.
- [x] **R3** [rabbitmq] Policies (DLX at-least-once + `reject-publish`; retry TTL 30 s). *Teste*: smoke prova retry após nack e DLQ após esgotar; `smoke-edge.sh` cobre a renderização. Atualizar `docs/integration/add-app.md` e `docs/INDEX.md`.
- [x] **L1** [legado] SQL Server na rede `workspace-data` por override de compose. *Teste*: conexão a partir de container na rede. Feito (legado-cadastro-usuarios #13).
- [x] **L2** [legado] Chave HMAC do Cadastro restrita a consulta e marcação; `legacy_app` com DENY no esquema `import`. *Teste*: integração (Testcontainers) cobrindo 200 nas rotas permitidas e 403 em `credential-verifications`. Feito (legado-cadastro-usuarios #13).
- [x] **K0** [Keycloak] Client `cadastro-importer` (menor privilégio), role `user-importer`, atributo `importLineId`, SMTP Mailpit. *Teste*: smoke do realm. Feito (Keycloak #12).
- [x] **C1** [cadastro] Esquema `import` (migrations por `cadastro_migrator`, runtime `cadastro_app`), entidades Lote/Linha, cifra dos dados pessoais, ADR-0007. *Teste*: unitários de domínio e integração das migrations. Feito (cadastro #11).

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
  - Status (2026-11-26): E2E real **passou** (11/11, 5.000 linhas, 4.950 criadas sem perda nem duplicata, 409 no reenvio, idempotência, retry/DLQ, zero dado do CSV em logs e payloads AMQP); `cadastro/scripts/e2e-import.sh`, relatório em [e2e-report.md](e2e-report.md). Quality Gate aprovado (ver acima). Os PRs do MVP foram mergeados na `master` dos quatro repositórios (rabbitmq #5, Keycloak #12, legado #13, cadastro #11).
- [x] **J1** Job de limpeza por retenção no Cadastro (cadastro #12, 2026-11-26): lotes com relatório vencido (90 dias, com as linhas e os dados cifrados das que terminaram em erro) e auditoria com mais de 12 meses, a cada 6 h, em lotes de 500 (spec §8 Q9). Testes: unitários do caso de uso e integração com SQL Server real. Decisão de 2026-11-26: lote esquecido em *aguardando confirmação* é cancelado após **7 dias**, com os dados das linhas apagados (cadastro, branch DEV-013).
- [x] **D1** README da importação (diagrama, como rodar, CSV de exemplo com linhas inválidas; screenshots no lugar do GIF) em `cadastro/docs/user-imports.md`.
- [x] **D2** Card do projeto no Site Principal e tabela do README de perfil (`cfo-cassiooliveira`) citam a importação em lote (Site-Principal #10 e cfo-cassiooliveira #7, 2026-11-26).
- **O1** (fora do MVP, spec §8 Q1): painel, alertas e Graylog, concluída depois; ver *Depois do MVP*.

## Depois do MVP

Plano aprovado em 2026-11-26 (equipe de agentes, até 3 em paralelo). Cada onda termina utilizável; o que não couber sai inteiro.

### Onda 1
Base: `master` do `cadastro` (`fe50a59`) com Quality Gate aprovado em 2026-11-26 (cobertura 92,4%; código novo 91,6%, 0 issues novas) e 731 testes .NET.

- [x] **P1** OTP recente só nas ações que mudam estado; leituras exigem a role e sessão com segundo fator, sem limite de idade, e a renovação do token atualiza as roles (cadastro #17, ADR-0010 do cadastro). E2E real 11/11 e Quality Gate aprovado.
- [x] **P2** Testes instáveis: outbox/consumidor sob carga e arquivo temporário preso no Windows (cadastro #17).
- [x] **O1** Painel da fila/retry/DLQ no Grafana, alerta de retry parada e acesso negado no stream de segurança do Graylog (workspace-grafana #6, graylog #17).
- [x] **P3** Claim `account_origin` (importada ou migrada) no client do Cadastro, de atributo que só o administrador altera (Keycloak #13).

### Onda 2
- [ ] **P4** XLSX e PDF na importação: **adiado** (decisão de 2026-11-27). Três revisões reprovaram arquivos hostis que derrubam o processo (estouro de pilha no PDF e no XLSX; memória no XLSX). Retomar com leitura própria ou em processo isolado; o trabalho está na branch local `wip/xlsx-import` do `cadastro` (não integrar como está).
- [x] **P5** Login social só com Google, apenas para contas existentes; credenciais só no `.env` (Keycloak #14, ADR-0009 do Keycloak). Quality Gate aprovado. Teste manual com conta Google aprovado pelo responsável em 2026-11-27 (negação sem conta, vínculo com a senha e segundo acesso direto).

### Onda 3
- [ ] **P6** ADR-0008: evento `identity.user.migrated.v1` consumido pelo Legado, que responde com um evento de resultado para o relatório não perder informação (`rabbitmq`, `cadastro`, `legado-cadastro-usuarios`). **Adiado** para depois do plano de 2026-11-26.

### Onda 4
- [x] **P7** Fechamento em 2026-11-27 sobre as versões finais: E2E real com 5.000 linhas 11/11 (`cadastro` `6e9105c`); Quality Gate aprovado no `cadastro` (805 testes .NET) e no `Keycloak` (415 testes). Teste manual do login com Google aprovado.

Corrigido no caminho: o nginx do front recusava envios acima de 1 MB (cadastro #18) e os rótulos do resumo vazavam em telas estreitas (cadastro #19).

Fora deste plano: Fluent Bit 5.2.1 (issue #3, a partir de 2026-12-08).
