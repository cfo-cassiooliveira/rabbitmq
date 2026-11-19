# ADR-0001: Imagem `rabbitmq:4.x-management` e execução single-node em Docker

- **Status**: Aceito
- **Data**: 2026-11-19
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. II.1, Art. III.4, Art. IV.7, Art. VII

## Contexto

Os projetos do workspace precisam de um broker local, reutilizável e sem passos manuais. A stack padrão fixa RabbitMQ 4.x (`stack.md`).
O host é Windows 11 com Docker Desktop/WSL2 (VM de 20 GB compartilhada com Graylog, Grafana, Keycloak etc.).

## Decisão

1. Imagem oficial **`rabbitmq:4.3-management`**, resolvida para **RabbitMQ 4.3.8 (GA)** e fixada por **tag + digest** (`sha256:fd4626e7c8ff066fc2ad8a608fd0364419ca919de00ddaca4bf1159f8350c1c8`) em `docker-compose.yml` e em `RABBITMQ_IMAGE` do CI; a varredura do Trivy no CI bloqueia CVE HIGH/CRITICAL com correção.
2. **Single-node** em Docker Compose, volume nomeado `rabbitmq-data`, `restart: unless-stopped`, `mem_limit: 1g`, healthcheck com `rabbitmq-diagnostics`.
3. Plugins: `rabbitmq_management` e `rabbitmq_prometheus`. Shovel/federation não são habilitados (sem necessidade presente; YAGNI).
4. Portas publicadas só em `127.0.0.1`: 5672 (AMQP), 15672 (management), 15692 (Prometheus), 5671 (AMQPS, só com o complemento `docker-compose.tls.yml`). Estão livres hoje; usar as portas padrão evita configuração extra nos clientes. EPMD/25672 não publicados.
5. Rede externa de nome fixo **`workspace-messaging`** (padrão do `workspace-identity`), criada por `scripts/messaging-network.sh`.

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Cluster de 3 nós | Tolerância a falha, quorum real | 3x memória, complexidade, sem ganho em dev | Rejeitada para dev; vira ADR de produção |
| `bitnami/rabbitmq` | Conveniência | Imagens Bitnami passaram a comercial | Licença/risco |
| Instalação nativa no Windows | Sem Docker | Erlang/versões manuais, fora do padrão do workspace | Inconsistente com os demais projetos |

## Consequências

- **Positivas**: simples, igual ao padrão dos projetos de infra; reprodutível.
- **Negativas / riscos**: quorum queue com uma réplica não tolera perda do nó; volume nomeado some com `down -v`; o digest fixado impede atualização silenciosa, mas exige bump manual da tag+digest (compose e CI) para receber correções.
- **Ações decorrentes**: tag/digest resolvidos na T02 (concluída); ADR de produção (cluster, TLS obrigatório) numa fase futura.
