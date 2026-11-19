# ADR-0002: Topologia, nomenclatura e definitions versionado + provisionador

- **Status**: Aceito
- **Data**: 2026-11-19
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. III.4, Art. IV.4, Art. VII.4, Art. VIII, Art. IX

## Contexto

O steering permite declarar topologia no código da aplicação ou via `definitions.json` versionado. As definitions contêm hashes de senha dos
usuários, que não devem ser versionados. O import no boot é aditivo (não remove o que sumiu do arquivo).

## Decisão

1. Nomenclatura do steering: exchange `<context>.events` (topic), routing key `<context>.<entity>.<event>.v<N>`, fila `<consumer>.<purpose>`, DLQ `<queue>.dlq` via `<context>.dlx`.
2. O **broker é dono** de: vhosts, usuários, permissões, policies (DLX por contexto, `delivery-limit`) e da topologia de **smoke**. A topologia de negócio de cada serviço é declarada por ele (código idempotente) dentro do prefixo permitido ao seu usuário.
3. `definitions/definitions.template.json` é versionado e **sem segredos**; `scripts/render-definitions.sh` gera `definitions/definitions.json` (gitignored) com `password_hash` calculado a partir do `.env`. O broker importa o arquivo no boot (`definitions.local.path`, `definitions.skip_if_unchanged = true`).
4. **Provisionador** (one-shot, via API de management) garante o que o import aditivo não faz: remover `guest` e itens obsoletos, e validar o resultado. Idempotente.
   Escopo do prune (implementado em `provisioning/provision.sh`): o provisionador só remove usuários e policies dentro do escopo do template (vhosts e usuários gerenciados); o broker é dono só do que está no template. Usuários fora do template só são removidos se não tiverem permissão em vhost fora dos vhosts do template; policies só são removidas nos vhosts do template. Usuários e policies de outros vhosts não são apagados. Filas e exchanges nunca são removidas.
   Fluxo de mudança do template: editar o template, `./scripts/render-definitions.sh`, `docker compose restart rabbitmq` (o import só roda quando o arquivo muda) e `docker compose run --rm provisioner`.
5. Quorum queues por padrão: `default_queue_type: quorum` no vhost `dev` das definitions e `x-queue-type: quorum` explícito nas filas de smoke. Vhost por ambiente: `dev` agora.
6. **Confirmado**: dead-lettering `at-least-once` em quorum queues exige `overflow: reject-publish` (policy do template: `dead-letter-strategy: at-least-once`, `overflow: reject-publish`, `delivery-limit: 5`); o smoke (`tests/smoke/smoke.py`, seção d) prova `nack(requeue=false)` -> DLX -> DLQ com `x-death` (`reason=rejected`, fila de origem). O `password_hash` é calculado por `scripts/render-definitions.sh` e aceito pelo broker no import (o smoke autentica `admin` e `smoke-app` com as senhas do `.env`).

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Só `definitions.json` versionado completo | Simples | Hashes de senha no git | Viola Art. IV.4 |
| Só provisionamento por script (API/rabbitmqctl) | Sem arquivo gerado | Menos declarativo, difícil de revisar | Perde revisão por diff |
| Topologia só no código das apps | Autonomia | Sem permissões/policies centrais | Complementar, não substitui |

## Consequências

- **Positivas**: revisável por diff; sem segredos no repo; idempotente.
- **Negativas / riscos**: dois passos (render + provision); drift se alguém mexer pela UI (a UI não é fonte de verdade).
- **Ações decorrentes**: T03, T04; procedimento `add-app` no README (T11).
