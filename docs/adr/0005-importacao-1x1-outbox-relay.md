# ADR-0005: Publicação 1x1 com Outbox por pessoa e relay com publisher confirms

- **Status**: Aceito
- **Data**: 2026-11-25 (recriado a partir do plano de 24/11 no Notion)
- **Decisores**: responsável técnico
- **Artigos da Constituição relacionados**: Art. VII.1-VII.4, Art. IV.6, Art. IX.1-IX.2

## Contexto

A importação em lote recebe uma lista de pessoas e precisa criar o acesso de cada uma. O broker (spec 001) está pronto. É preciso decidir a granularidade das mensagens e como publicá-las sem perda nem dual write, com dados pessoais fora do broker.

## Decisão

1. **Uma mensagem por pessoa (1x1)**, não uma mensagem por lote. Routing key `cadastro.user-import-line.accepted.v1` na exchange `cadastro.events`.
2. A mensagem leva só `batchId` e `lineId` no `data`; dados pessoais ficam **cifrados no banco** do Cadastro e são apagados quando a linha termina.
3. Ao confirmar o lote, grava-se **uma linha de outbox por pessoa** na mesma transação; um relay (`BackgroundService`) publica com **publisher confirms**, mensagens persistentes e `mandatory`, e marca a linha como enviada.
4. Consumo em fila quorum `cadastro.user-import-lines`, prefetch 10, ack manual após o commit, inbox por `messageId`. Retry por fila com TTL 30 s (até 5 ciclos); falha definitiva ou esgotamento vai à DLQ via `cadastro.dlx`.
5. Limite de 10 criações por segundo no consumidor para proteger a Admin API do Keycloak.

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Uma mensagem por lote | Menos mensagens | Uma linha ruim afeta o lote; retry e DLQ só por lote; sem paralelismo | Pior isolamento de falha |
| Publicar direto, sem outbox | Mais simples | Dual write: perda ou fantasma se algo falhar entre banco e broker | Viola Art. VII.3 |
| Dados pessoais na mensagem | Consumidor sem consulta ao banco | PII no broker, em DLQ e em backups | Viola LGPD e Art. IV.6 |
| Processar em memória no BFF (sem broker) | Sem infraestrutura | Perde-se no restart; sem retry/DLQ; não demonstra mensageria | Não atende o objetivo |

## Consequências

- **Positivas**: isolamento de falha, retry e DLQ por linha, paralelismo controlado, sem perda por falha do broker, PII fora da mensageria.
- **Negativas / riscos**: até 5.000 linhas de outbox por lote e relay a operar; duplicatas são esperadas (consumidor idempotente obrigatório); consulta ao banco por mensagem.
- **Ações decorrentes**: topologia R1-R3 no broker; outbox/relay C4; inbox C5b; contrato `.v1` versionado.
