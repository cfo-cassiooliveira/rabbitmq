# Spec 002 — Importação em lote 1x1 de usuários (uso do broker pelo Cadastro)

- **Status**: Aceita (2026-11-25); MVP até 04/12/2026; decisões Q1-Q10 em §8. Recriada a partir do plano no Notion "Caminho do portfólio" e "Projeto do portfólio"; o texto original de 24/11 não foi versionado) · **Escopo**: `rabbitmq` (topologia), `cadastro` (funcionalidade), `legado-cadastro-usuarios` (rede de dados, esquema e API interna) e `Keycloak` (client e role).
- **ADRs**: 0005 (1x1 com Outbox e relay), 0006 (usuário nasce migrado, sem senha, sem consultar o legado). Previstos: 0007 (banco compartilhado com o Legado, exceção ao Art. III.4) e 0008 (evento `identity.user.migrated.v1`, depois do MVP).

> Itens marcados com **[SUPOSIÇÃO]** não constam no que foi recuperado do Notion e precisam de confirmação (ver §8).

## 1. Problema e objetivo

O RH ou um cliente envia uma lista de pessoas e o sistema precisa criar o acesso de cada uma. O broker RabbitMQ (spec 001) está pronto, mas nenhum projeto de aplicação o usa.
Objetivo: uma funcionalidade de admin no Cadastro que recebe um **CSV**, valida, e cria **cada pessoa como uma mensagem** (1x1) no RabbitMQ; um consumidor idempotente cria o usuário **já migrado no Keycloak**, sem consultar o legado.

Métricas de sucesso:
- Lote de 5.000 linhas processado sem perda, sem duplicidade e sem derrubar o broker (limite de 10 criações/s no Keycloak).
- Reenviar o mesmo arquivo não cria ninguém de novo.
- Uma linha ruim não afeta as demais; falhas definitivas aparecem no relatório e na DLQ.
- 0 CPF/e-mail em logs, mensagens ou relatórios; dados pessoais apagados quando a linha termina.

## 2. Fluxo

1. O admin envia o CSV pela tela. A API (BFF) verifica o arquivo no antivírus (ClamAV; se não puder verificar, **recusa**) e valida em streaming: cabeçalho, tamanho, limite de linhas, obrigatórios, e-mail, CPF e duplicados no arquivo.
2. A API cria o **Lote** em `AwaitingConfirmation` e mostra o resumo. Ao **confirmar** (2 passos), grava **uma linha de outbox por pessoa** (Transactional Outbox, Art. VII.3).
3. O relay publica **uma mensagem por pessoa** com publisher confirms em `cadastro.events`, routing key `cadastro.user-import-line.accepted.v1`. A mensagem leva só `batchId` e `lineId`; os dados pessoais ficam **cifrados no banco** e são apagados quando a linha termina.
4. O consumidor (fila quorum `cadastro.user-import-lines`, prefetch 10, máx. 10 criações/s) é **idempotente**: inbox por `messageId` e atributo `importLineId` no Keycloak.
5. Cada linha vira usuário **já migrado** no Keycloak pela Admin API, client `cadastro-importer` (menor privilégio), **sem senha**, ação obrigatória `UPDATE_PASSWORD` e e-mail de ativação (72 h; Mailpit em dev).
6. Falha temporária volta por fila de retry (TTL 30 s, até 5 ciclos). Falha definitiva ou esgotamento vai para a **DLQ**.
7. Depois de criar no Keycloak, o consumidor **marca no Legado** que o login foi migrado, pela API interna existente (consulta + marcação; timeout, retry e circuit breaker). Só marca com **um único candidato de e-mail exatamente igual**; login inexistente não é erro; ambiguidade vira aviso na linha. Falha na marcação **não desfaz** o usuário do Keycloak.
8. O progresso do lote é acompanhado e o relatório por linha (criado, já existente, erro + motivo, sem dados sensíveis) está disponível, com opção de **reprocessar erros**.

## 3. Histórias e critérios de aceite

**H1 — Enviar e validar o arquivo.**
```gherkin
Dado um admin com a role user-importer e OTP recente
Quando envia um CSV UTF-8 válido de até 5 MB e 5.000 linhas
Então o lote fica "aguardando confirmação" com o resumo (válidas, inválidas, duplicadas)
E nenhuma mensagem é publicada ainda
```
```gherkin
Cenário: arquivo recusado
Quando o arquivo excede o limite, tem cabeçalho inesperado, não é UTF-8 ou o ClamAV está indisponível
Então a API responde 4xx/5xx em Problem Details, sem criar lote
```
```gherkin
Cenário: sem permissão
Quando um usuário sem a role user-importer (ou sem OTP recente) chama /api/v1/user-imports
Então recebe 403 e o acesso negado é auditado
```

**H2 — Confirmar e publicar 1x1.**
```gherkin
Dado um lote aguardando confirmação com N linhas válidas
Quando o admin confirma
Então são gravadas N linhas de outbox na mesma transação que muda o lote para "em processamento"
E o relay publica N mensagens com confirm, cada uma com apenas batchId e lineId
```
```gherkin
Cenário: broker fora do ar
Quando o relay não recebe o confirm
Então a linha de outbox permanece pendente e é reenviada depois, sem perda
```

**H3 — Criar o usuário no Keycloak, idempotente.**
```gherkin
Quando a mensagem de uma linha é consumida
Então o usuário é criado sem senha, com UPDATE_PASSWORD, importLineId e e-mail de ativação
E a linha fica "criado"
```
```gherkin
Cenário: mensagem duplicada ou pessoa já existente
Quando a mesma mensagem chega duas vezes, ou o e-mail já existe no Keycloak
Então ninguém é duplicado e a linha fica "já existente"
```
```gherkin
Cenário: reenvio do mesmo arquivo
Quando o mesmo arquivo (mesmo hash) é enviado de novo
Então não são criados novos usuários
```

**H4 — Falhas.**
```gherkin
Cenário: falha temporária (Keycloak 5xx/timeout)
Então a mensagem vai à fila de retry (TTL 30 s) e volta, até 5 ciclos
Cenário: falha definitiva ou 5 ciclos esgotados
Então a mensagem vai à DLQ e a linha fica "erro" com motivo, sem dados pessoais
```

**H5 — Marcar no Legado.**
```gherkin
Dado um usuário criado no Keycloak e um único usuário do Legado com o mesmo e-mail
Então o Legado registra MigratedAt e KeycloakUserId
Cenário: nenhum candidato -> nada a marcar, não é erro; vários candidatos -> aviso na linha
Cenário: API do Legado indisponível -> o usuário do Keycloak permanece e LegacyMarkStatus fica pendente
```

**H6 — Acompanhar o lote.**
```gherkin
Quando o admin abre a tela de lotes
Então vê progresso por estado, o detalhe por linha, pode reprocessar erros e baixar o relatório
```

## 4. Requisitos não funcionais

- **Segurança**: role `user-importer` + OTP recente; service account do importador separada da de leitura; antivírus fail-closed; trilha de auditoria; `cadastro-app` no broker com permissões mínimas (configure nenhum; write só em `cadastro.events` e `cadastro.retry`; read só em `cadastro.user-import-lines`).
- **LGPD**: só ids na mensagem; dados pessoais cifrados e apagados ao fim da linha; arquivo descartado após o processamento; CPF/e-mail fora de qualquer log (Graylog já mascara).
- **Confiabilidade**: Outbox, publisher confirms, consumidor idempotente, retry com TTL, DLQ (Art. VII).
- **Observabilidade**: logs estruturados com `trace_id`/`correlation_id`; métricas de lote e fila no Grafana (opcional).
- **Contrato**: evento `cadastro.user-import-line.accepted.v1` versionado (Art. IX).
- **Banco**: esquema `import` no SQL Server do Legado, com logins `cadastro_migrator` (migrations) e `cadastro_app` (runtime) sem acesso ao `dbo`; `legacy_app` com DENY no esquema `import`. Exceção ao Art. III.4 registrada no ADR-0007 com plano de saída.

## 5. Fora do escopo do MVP

XLSX e PDF (novos `IExtratorDeUsuarios`), claims customizados e login social no Keycloak, painel do lote e alertas de DLQ no Grafana, evento `identity.user.migrated.v1` (ADR-0008), OCR/IA, Kubernetes local.

## 6. Riscos

- Quem existir no Legado e na planilha fica com contas separadas até a marcação (ou sem ela, em ambiguidade).
- Banco compartilhado com o Legado viola o Art. III.4 (aceito pelo responsável técnico, ADR-0007).
- Escopo maior que o desenho antigo: o prazo de 27/11 do MVP não comporta tudo (ver §8, Q1).

## 7. Contratos

| Item | Valor |
|---|---|
| Exchange de eventos | `cadastro.events` (topic) |
| Routing key | `cadastro.user-import-line.accepted.v1` |
| Fila principal | `cadastro.user-import-lines` (quorum, prefetch 10) |
| Retry | exchange `cadastro.retry`, fila `cadastro.user-import-lines.retry` (TTL 30 s) |
| DLQ | exchange `cadastro.dlx`, fila `cadastro.user-import-lines.dlq` (convenção do steering `messaging-rabbitmq.md`) |
| Topologia total | 3 exchanges (`cadastro.events`, `cadastro.retry`, `cadastro.dlx`), 3 filas, 3 policies (nomes das policies em §8, Q7) |
| Envelope | CloudEvents-like do steering (`messageId`, `type`, `source`, `occurredAt`, `correlationId`, `causationId`) + `traceparent` nos headers |
| Payload (`data`) | `{ batchId, lineId }` (sem dados pessoais) |
| Endpoint | `/api/v1/user-imports` (role `user-importer`) |

## 8. Decisões (respondidas em 2026-11-25)

| # | Decisão |
|---|---|
| Q1 | MVP movido de 27/11 para **04/12/2026**. Painel Grafana e stream Graylog (O1) saem do MVP. **ClamAV permanece.** |
| Q2 | Acompanhamento por **polling** na tela; SignalR depois do MVP. |
| Q3 | Só logs estruturados com `correlation_id` no MVP; painel e alerta de DLQ depois. |
| Q4 | 5 MB, 5.000 linhas, link de ativação de 72 h. |
| Q5 | **AES-256-GCM**, chave por variável de ambiente (cofre depois), identificador de versão da chave gravado no registro; sem rotação automática no MVP. |
| Q6 | CSV com **nome, e-mail e CPF obrigatórios** (CPF validado pelos dígitos e guardado cifrado); telefone opcional; sem endereço. |
| Q7 | Policies `cadastro-dlx` (DLX at-least-once + `reject-publish`), `cadastro-retry` (TTL 30 s, DLX de volta à fila principal) e `cadastro-limits` (limite de entregas). |
| Q8 | Reprocessar é manual, só linhas com erro definitivo, sem limite de vezes; cada tentativa é registrada. |
| Q9 | Relatório por linha retido 90 dias; auditoria 12 meses. Dados pessoais da linha são apagados ao fim dela **quando criada ou já existente**; linha com **erro definitivo** mantém os dados cifrados para o reprocessamento manual (Q8) até o job de limpeza ou 90 dias, e `Cancel()` do lote apaga os dados das linhas pendentes. Emenda de 2026-11-25, após a revisão da C1 (ADR-0007 do cadastro). |
| Q10 | Exceção ao Art. III.4 confirmada (ADR-0007), com plano de saída: banco próprio do Cadastro quando o Legado deixar de existir ou quando o ADR-0008 (evento) entrar. |
