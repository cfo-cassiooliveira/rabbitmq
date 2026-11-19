# Spec 001 — Broker RabbitMQ 4.x local

- **Status**: Aceita (2026-11-19); ADRs 0001-0004 aceitos; T12 pendente. Proposta em 2026-11-18 · **Escopo**: somente `C:\Workspace\rabbitmq`; nenhum outro projeto é alterado.

## 1. Problema e objetivo

Os projetos do workspace (cadastro, legado, keycloak) precisarão de mensageria assíncrona (Constituição, Art. VII), mas não há broker.
Objetivo: um RabbitMQ local em Docker, **configurado como código**, seguro por padrão, observável (métricas para o Grafana e logs para o Graylog
sem perda) e verificado por teste ponta a ponta, pronto para os demais projetos na fase seguinte.

Métricas de sucesso:
- `docker compose up -d` leva o broker a `healthy` em até 2 min numa máquina limpa, sem passo manual na UI.
- Smoke test 100% verde: publish com confirm, quorum queue, consume/ack, DLQ após nack, `guest` inoperante, permissões mínimas, health, definitions idempotentes, métricas e fallback de logs.
- 0 segredos versionados (gitleaks limpo) e 0 dados pessoais nos logs do broker.

## 2. Histórias e critérios de aceite

**H1 — Subir o broker.**
```gherkin
Dado que a rede workspace-messaging existe e o .env foi gerado
Quando executo "docker compose up -d --build"
Então o serviço rabbitmq fica healthy
E o provisionador termina com código 0
E a UI de management responde em http://localhost:15672
```
```gherkin
Cenário: .env ausente
Quando executo "docker compose up" sem .env
Então o compose falha com a mensagem "defina ... no .env"
```

**H2 — Segurança de acesso.**
```gherkin
Quando tento autenticar como guest/guest por AMQP e pela API de management
Então recebo ACCESS_REFUSED / 401
```
```gherkin
Dado o usuário smoke-app com permissões restritas ao prefixo "smoke."
Quando ele tenta declarar a fila "other.queue" ou publicar em "other.events"
Então o broker recusa com ACCESS_REFUSED (403)
```

**H3 — Mensageria confiável.**
```gherkin
Dado o exchange smoke.events e a quorum queue smoke-consumer.ping
Quando publico com mandatory e publisher confirm
Então recebo o ack de confirm e a mensagem é entregue ao consumidor e confirmada com ack manual
```
```gherkin
Quando o consumidor responde nack com requeue=false
Então a mensagem chega em smoke-consumer.ping.dlq via smoke.dlx
```
```gherkin
Cenário: sem rota
Quando publico com mandatory em routing key sem binding
Então recebo basic.return (a mensagem não é perdida em silêncio)
```

**H4 — Configuração idempotente.**
```gherkin
Quando reinicio o broker e reexecuto o provisionador duas vezes
Então as definitions (vhosts, usuários, permissões, policies, exchanges, filas, bindings) ficam idênticas e sem erro
```

**H5 — Métricas para o Grafana.**
```gherkin
Quando consulto http://127.0.0.1:15692/metrics
Então recebo métricas Prometheus do broker, inclusive por fila
E a porta só é publicada em 127.0.0.1
E o broker expõe a rede interna rabbitmq-metrics para o Prometheus do Grafana entrar na fase seguinte
```
```gherkin
Cenário: insumos do Grafana documentados
Então docs/integration/grafana-inputs.md lista alvo, rede, dashboards oficiais (10991 rev 15, 11352 rev 10, 11350 rev 8) e alertas (fila crescendo, sem consumidor, memória, disco, DLQ não vazia)
E nenhum arquivo de C:\Workspace\grafana é alterado
```

**H6 — Logs no Graylog sem perda.**
```gherkin
Dado o broker, o coletor de logs e o Graylog no ar
Quando o broker gera um evento de log
Então o evento fica no arquivo JSON local e chega ao Graylog com service_name "rabbitmq"
```
```gherkin
Cenário: Graylog fora do ar
Dado que o destino GELF está indisponível
Quando o broker gera eventos de log
Então o arquivo local registra todos
E scripts/logs-fallback-check.sh mostra os logs retidos e o backlog pendente maior que zero
Quando o destino volta
Então todos os eventos chegam, sem perda (duplicatas são toleradas)
```
```gherkin
Cenário: coletor reiniciado com o destino fora
Quando reinicio o coletor com o destino indisponível e depois religo o destino
Então os eventos pendentes ainda chegam (buffer e offsets em disco)
```
```gherkin
Cenário: LGPD
Então nenhum log contém senha, token ou dado pessoal; apenas nomes técnicos de app/usuário, vhost e filas
```

## 3. Experiência do usuário

Sem tela própria: a única UI é o management oficial (não customizada). Mensagens de erro dos scripts em PT-BR e acionáveis
(ex.: "rede workspace-messaging ausente: rode ./scripts/messaging-network.sh").

## 4. Requisitos não funcionais

- Segurança: Art. IV (segredos no `.env` gerado; portas só em `127.0.0.1`; `guest` removido; hashes em vez de senhas nas definitions).
- Confiabilidade: filas quorum, mensagens persistentes, volumes nomeados, healthcheck, `restart: unless-stopped`; logs com buffer em disco.
- Recursos: broker `mem_limit` 1g com watermark absoluto e `disk_free_limit`; coletor com `mem_limit` e buffer com teto; rotação e retenção do log definidas.
- Operação Windows 11 + Docker Desktop/WSL2: volumes nomeados; config em LF.
- LGPD: nenhum dado pessoal no broker nem nos logs; conteúdo das mensagens é responsabilidade dos serviços (fase seguinte).

## 5. Fora de escopo

Integração de qualquer app; cluster; alterações em `grafana/` e `graylog/` (tarefas F01/F02, com aprovação); OAuth2/Keycloak na UI; federation/shovel; streams; MQTT/STOMP; produção.

## 6. Premissas

Single-node; imagem oficial; vhost `dev`; rede `workspace-messaging`; portas padrão em `127.0.0.1` (5672, 15672, 15692, 5671 livres; em uso 9000, 9001, 9100, 3000, 8025, 8180, 12201/12202).
Coletor Fluent Bit (Apache-2.0) com GELF TCP para `graylog:12201` (o Graylog já publica TCP, UDP e HTTP). Perguntas abertas e recomendações: [summary.md](summary.md).

## 7. Insumos da fase seguinte (o que o broker entrega)

- **Apps**: host `rabbitmq` na rede `workspace-messaging` (ou `localhost`); portas 5672/5671; vhost `dev`; um usuário por app (procedimento `add-app`: usuário, permissões por prefixo, policy DLX do contexto); convenções do steering; segredos no cofre/`.env` de cada app.
- **Grafana (F01, com aprovação)**: alvo `rabbitmq:15692`, rede `rabbitmq-metrics`, dashboards 10991/11352/11350 por revisão, alertas (fila crescendo, sem consumidor, memória/disco, DLQ não vazia, broker fora, backlog do coletor). Segue o padrão do `grafana/`: `file_sd`, dashboards/alertas por arquivo, pasta e label `rabbitmq`.
- **Graylog (F02, com aprovação)**: stream "RabbitMQ - Infra" por `service_name:rabbitmq`, retenção, regra de pipeline, alertas.
