# Relatório E2E real — Spec 002, tarefa E1 (importação em lote 1x1)

- **Data**: 2026-11-25/26 · **Execução de referência**: run `mwws0dcx` (23:50 → 00:03 UTC, 13,6 min, 11 testes, todos passaram).
- **Stack**: real, sem mocks e sem Testcontainers (Keycloak, Mailpit, RabbitMQ, SQL Server do Legado, Legado API/web, ClamAV, Cadastro API/web).
- **Como reproduzir**: `cadastro/scripts/e2e-import.sh` (roda no host; usa o CLI do Docker). Código em `cadastro/e2e/import-real/`
  (`import-real.spec.js`, `support/csv.js`, `support/stack.js`). Resultados brutos: `cadastro/e2e/.artifacts/import-real/results.json` (não versionado).
- **Dados**: 100% fictícios (nomes sintéticos terminados em "Sintetico", e-mails `@example.test` únicos por execução, CPFs com dígitos verificadores calculados por algoritmo).

## 1. Como a stack foi subida (ordem real)

1. Redes `workspace-identity`, `workspace-data` (`legado/scripts/identity-network.sh`, `data-network.sh`); `workspace-messaging` já existia (RabbitMQ).
2. **Legado** (`legado-cadastro-usuarios`): `.env` criado (segredos gerados com openssl, gitignored), `internal-credentials.sh` (CA, certificado, chaves HMAC, senhas `cadastro_migrator`/`cadastro_app`), `log-pseudonymization-key.sh`;
   `docker compose -f docker-compose.yml -f docker-compose.identity.yml -f docker-compose.data.yml up -d --build` (o migrator criou o esquema `import` e os logins).
3. **Keycloak**: já de pé e provisionado (client `cadastro-importer`, role `user-importer`, atributo `importLineId` e SMTP conferidos pela Admin API). Foi adicionado `KC_LEGADO_SIGNING_KEY` ao `.env` e o container recriado (ver defeito 1).
4. **RabbitMQ**: `docker compose build provisioner` → `render-definitions.sh` → `restart rabbitmq` → `run provisioner` (`[provision] ok`; antes o provisioner antigo saía com `operator policy missing: dev/cadastro-limits`).
5. **Cadastro**: `generate-env.sh`, `migrate-import-db.sh` (migration `InitialImportSchema` aplicada) e
   `docker compose -f docker-compose.yml -f docker-compose.data.yml -f docker-compose.messaging.yml -f docker-compose.import.yml up -d --build`.
6. Fora da subida (memória): Graylog, SonarQube, Grafana.

**Memória do Docker** (limite de 9,7 GiB): em repouso ~3,2 GiB somados; **pico medido durante os testes** (MiB, amostra a cada ~45 s + `docker stats`):
Keycloak 987 · ClamAV 947 · SQL Server 671 · cadastro-api 247 · RabbitMQ 219 · legado-api 142 · Postgres 128 · Mailpit 36 · web 9 · log-shipper 10. Soma dos picos ≈ 3,4 GiB.

## 2. Defeitos de ligação encontrados e corrigidos

| # | Defeito (evidência) | Correção mínima |
|---|---|---|
| 1 | `keycloak/docker-compose.yml` e `cadastro/scripts/generate-env.sh` apontavam para `../legado`, mas o repositório é `legado-cadastro-usuarios`. O Docker criou um **diretório vazio** `legado/secrets/internal/ca.crt` e o Keycloak rodava com um diretório no lugar da CA do Legado; `generate-env.sh` não achava chaves do Legado. | Caminhos trocados para `../legado-cadastro-usuarios/...` (compose do Keycloak, `generate-env.sh` do Cadastro, README do Keycloak); Keycloak recriado (mount conferido com `docker inspect`); diretório-fantasma vazio removido. |
| 2 | `cadastro/scripts/generate-env.sh` gerava `CADASTRO_MIGRATOR_CONNECTION` com `Server=localhost,1433`: `migrate-import-db.sh` falhou duas vezes com timeout (error 258). Com `127.0.0.1` a migration aplicou em 10 s (no Windows `localhost` tenta `::1` e a porta só publica em IPv4). | Padrão de `CADASTRO_MIGRATOR_HOST` passou a `127.0.0.1`. |
| 3 | `cadastro-clamav-1` em **loop de restart** (`chown: Operation not permitted`) por `cap_drop: [ALL]`; com só CHOWN/SETUID/SETGID subia sem log (`install: can't change permissions of /run/clamav`). | `cap_add: [CHOWN, SETUID, SETGID, FOWNER, DAC_OVERRIDE]` mantendo `cap_drop: ALL` e `no-new-privileges`. Container ficou `healthy`. |
| 4 | Mailpit guarda só as **500 mensagens mais recentes** por padrão: na 1ª execução completa o teste achou 796 de 4.950 e-mails (a limpeza do Mailpit apagava evidência). | `MP_MAX_MESSAGES=10000` e `mem_limit` 256m no compose do Keycloak (Mailpit recriado). Depois disso: 4.950/4.950. |
| 5 | Sem relação com ligação, mas bloqueou o helper: `createInvestigator` só atribuía `log-investigator`. | Parâmetro opcional `role` (padrão inalterado) em `cadastro/e2e/support/services.js`. |

Duas execuções anteriores falharam por bugs do **próprio teste** (queue de espelho não-durável recusada pelo broker, resposta 201 sem corpo, índices de seeds fora do arquivo pequeno, DLQ com contador atrasado) e foram corrigidos; a tentativa de "ambiguidade" no Legado (dois logins com o mesmo e-mail) foi descartada: o Legado tem índice único em `NormalizedEmail` e o `UPDATE` por SQL foi recusado.

## 3. Resultados (execução de referência `mwws0dcx`)

### (a)(b)(c) Lote de 5.000 linhas pela UI real
- CSV: 5.000 linhas de dados = 4.950 válidas + 20 inválidas (CPF inválido, e-mail inválido, nome ausente, CPF ausente) + 30 duplicadas.
- Login real no Keycloak (senha + OTP), upload em `/imports/new`, resumo na tela **Válidas 4950 · Inválidas 20 · Duplicadas 30** (igual ao da API), nenhuma mensagem no broker antes da confirmação (fila-espelho com 0), confirmação (202).
- **Tempo total 504 s (8,4 min); no servidor 498 s; vazão 9,94 criações/s** (limite configurado: 10/s). Estado final **Completed**: 4.950 criadas, 0 existentes, 0 erro, 0 pendentes.
- Acompanhamento pela API/UI com polling de 20 s. Foram necessários **3 step-ups de OTP** em ~17 min (a policy exige OTP de no máximo 5 min em *todas* as chamadas do grupo, inclusive as de leitura; ver §5).

### (d) Keycloak e Mailpit
- **4.950** usuários com atributo `importLineId` para o CSV, 4.950 `importLineId` distintos, 4.950 e-mails distintos, **0** CPF/linha do CSV faltando.
- **0** usuários com credencial de senha; **0** sem `requiredAction UPDATE_PASSWORD`; 0 desabilitados.
- Mailpit: **4.950** e-mails de ativação, **0** destinatários com mais de um. Link de ativação (token `execute-actions`): `exp − envio = 259.200 s` (**72 h exatos**).

### (e) Reenvio do mesmo arquivo
- `409 import.duplicate_file`, tela mostra "Ver o lote existente"; usuários do Keycloak antes/depois: 10.374/10.374 (nenhum novo).

### (f) Idempotência
- Uma mensagem já processada foi republicada com o admin do broker (mesmo `messageId`, `routed: true`). Após 25 s: linha continua `Created`, e-mails 4.950 → 4.950, usuários 10.374 → 10.374, DLQ 9 → 9, fila principal vazia. **Efeito 1x.**
- Não verificado: republicar a mesma linha com **outro** `messageId` (o provisionador reenvia o e-mail se `UPDATE_PASSWORD` ainda estiver pendente; ver §5).

> **Nota posterior (2026-11-25):** esta execução plantou `<Rejeitado>` no nome para provocar a falha definitiva. Depois dela, o upload passou a recusar na validação os 24 caracteres que o Keycloak proíbe em nomes (`row.name_invalid`), então esse cenário não é mais alcançável por esse caminho. O E2E foi ajustado para plantar um primeiro nome de 105 caracteres, que o upload aceita e o Keycloak recusa (limite de 100). A mudança do cenário **não foi reexecutada** nos 14 min. Verificação direta no Keycloak real: `<` e `§` → 400 `error-person-name-invalid-character`; acentos, cedilha, til, trema, apóstrofo ASCII e tipográfico → 201; 100 caracteres → 201 e 101 → 400 `error-invalid-length-too-long`.

### (g) Resiliência (lote de 400 linhas: 397 válidas + 3 com `<Rejeitado>` no nome)
- Keycloak parado (`docker stop`) quando 50 linhas estavam criadas; fora do ar por 36 s (+ ~25 s de reinício até `healthy`). Fila `.retry` chegou a **33** mensagens (estatística do gerenciamento), voltou a 0.
- Lote concluiu `CompletedWithErrors`: **397 criadas**, 3 erro, 0 pendentes; 397 usuários, 397 e-mails distintos, **0 duplicata, 0 destinatário sem e-mail**.
- **Falha definitiva** (Keycloak responde 400 `error-person-name-invalid-character`): as 3 linhas ficaram `Error` com código `identity.rejected` e as 3 mensagens foram à DLQ. "Reprocessar linhas com erro" (UI) reenviou as 3, que falharam de novo (`reprocessCount` = 1 nas 3; DLQ +3).
- Não verificado: esgotamento dos **5 ciclos** de retry (o Keycloak voltou antes) e a transição para DLQ por esse caminho.

### (h) Verificação LGPD
Varredura em e-mails (nenhum), CPFs (11 dígitos e formatados), nomes (marcador "Sintetico") e marcador da execução, **com controle positivo** (o detector acha os três valores plantados):

| Alvo | Volume varrido | Ocorrências |
|---|---|---|
| Logs `cadastro-api` | 55,5 MB, 36.811 linhas | **0** |
| Logs `keycloak` | 9,0 MB, 10.752 linhas | **0** |
| Logs `legado-api` (inclui o cadastro de 3 logins com e-mail igual ao do CSV) | 4,6 MB, 5.358 linhas | **0** |
| Logs `cadastro-web`, `legado-web`, `clamav`, `rabbitmq` (+ migrator, SQL Server, Postgres, shipper: sem saída) | 0,2 MB | **0** |
| Payloads AMQP publicados (fila-espelho) | **5.708** mensagens | **0**; chaves de `data` = exatamente `batchId`, `lineId` |
| Mensagens da DLQ (incl. propriedades e `x-death`) | 15 | **0** |
| Esquema `import` (colunas texto com `@example.test`) | todas as tabelas | **0** linhas |
| Relatório CSV por linha (`/report`, 401 linhas) | 1 | **0** |

Mailpit foi excluído (guarda e-mails por natureza).

### (i) Marcação no Legado
- 2 logins do Legado com e-mail **exatamente igual** a linhas do CSV: ambos ficaram com `MigratedAt` e `KeycloakUserId` iguais ao id do usuário criado no Keycloak; linhas `Marked`.
- 1 login de controle (e-mail fora do CSV): **não marcado**. Distribuição das linhas: `NoCandidate` 4.948, `Marked` 2. Nenhum outro login do Legado marcado.
- Não verificado na stack real: ambiguidade (índice único no Legado impede dois logins com o mesmo e-mail) e API do Legado indisponível (cobertos por testes de integração da C5c).

### (j) Métricas finais
- Linhas por estado (lote grande): Created 4.950, AlreadyExists 0, Error 0, Pending 0, Cancelled 0. Lote pequeno: Created 397, Error 3.
- Filas ao final: principal 0, retry 0, **DLQ 15** (9 já existiam de execuções de teste anteriores; 6 desta execução: 3 + 3 do reprocessamento).
- Realm `workspace` guarda ~10,7 mil usuários fictícios importados (execuções de teste); não foram apagados.

## 4. Critérios H1-H6

| Critério | Resultado |
|---|---|
| **H1** upload e validação | OK: resumo 4950/20/30, nada publicado antes de confirmar. Recusas: cabeçalho inesperado `422 file.header_invalid`, ClamAV parado `503 scanner.unavailable` (fail-closed), sem lote criado (6 → 6). Sem a role: `403`. **Não verificado**: auditoria do acesso negado; arquivo > 5 MB/não UTF-8 (cobertos por testes). |
| **H2** confirmar e publicar 1x1 | OK: 5.708 mensagens vistas, uma por pessoa, só `batchId` e `lineId`. **Não verificado**: outbox na mesma transação e "broker fora do ar" (cobertos pela integração da C4). |
| **H3** criar no Keycloak, idempotente | OK: sem senha, `UPDATE_PASSWORD`, `importLineId`, e-mail 72 h, mensagem duplicada e reenvio do arquivo sem efeito. **Não verificado**: pessoa já existente no Keycloak (`AlreadyExists`). |
| **H4** falhas | OK: transitória (retry e recuperação sem perda) e definitiva (`identity.rejected`, DLQ, linha com código). **Não verificado**: 5 ciclos esgotados. |
| **H5** marcar no Legado | OK para candidato único e nenhum candidato. **Não verificado**: vários candidatos e Legado fora do ar. |
| **H6** acompanhar | OK: lista, detalhe com progresso, relatório CSV sem dado pessoal (via API) e reprocessar erros pela UI. **Não verificado**: clique no botão "Baixar relatório CSV"; screenshots em mobile/tablet/desktop nesta execução (só desktop, em `e2e/.artifacts/import-real/shot-*.png`; a matriz de dispositivos é do `user-imports.spec.js`). |

## 5. Observações e riscos (sem alteração; decisão de produto/dono)

1. **OTP a cada 5 min também na leitura**: quem acompanha um lote de ~8 min precisa digitar o OTP de novo (3 step-ups em 17 min). A tela trata o 403, mas o fluxo interrompe o acompanhamento. Decisão: exigir "OTP recente" só em upload/confirmar/reprocessar e deixar GETs só com a role?
2. **Volume de log da API**: 36.811 linhas/55 MB nesta execução, quase todas `Executed DbCommand` (Microsoft.EntityFrameworkCore) em Information, incluindo o polling do relay a ~1/s (parâmetros aparecem como `?`, sem dado pessoal). Sugestão: elevar `Microsoft.EntityFrameworkCore.Database.Command` para Warning.
3. **Reentrega com outro `messageId`** (mesma `lineId`) reenvia o e-mail de ativação enquanto a pessoa não ativou (comportamento da retomada do provisionador); não afeta a idempotência pedida (mesmo `messageId`), mas pode gerar e-mail repetido em reprocessamento manual.
4. Estatísticas do gerenciamento do RabbitMQ atrasam alguns segundos (contagem de DLQ lida cedo demais); o teste espera o contador.
5. O E2E usa `docker stop` no Keycloak; em máquina com outro E2E ou provisioner do Keycloak em execução, não rode (regra do CLAUDE.md do Cadastro).

## 6. O que NÃO foi verificado (resumo)

Quality Gate do SonarQube (SonarQube fora da stack por memória); matriz mobile/tablet/desktop da tela com a API real; broker fora do ar na publicação; 5 ciclos de retry esgotados; `AlreadyExists`; ambiguidade e indisponibilidade do Legado; auditoria do 403; Graylog (não subiu; só varredura dos logs dos containers, não do pipeline GELF).

## 7. Veredito da E1

O fluxo ponta a ponta com 5.000 linhas **passou** sem perda, sem duplicidade e sem dado pessoal em logs/AMQP. A E1 permanece **aberta no `tasks.md`** apenas pelo item "Quality Gate do SonarQube aprovado", que não foi executado.
