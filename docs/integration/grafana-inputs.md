# Insumos para o Grafana (tarefa F01, fora do escopo deste projeto)

Este documento reúne o que o projeto `C:\Workspace\grafana` precisa para consumir as métricas do RabbitMQ. **Nada foi
escrito em `grafana/`**: a F01 exige aprovação própria. Nomes de métricas e rótulos abaixo foram conferidos contra o
`/metrics` do broker de pé (RabbitMQ 4.3.8, `rabbitmq_prometheus`, `prometheus.return_per_object_metrics = true`).

## 1. Alvo de scrape e rede

| Item | Valor |
|---|---|
| Alvo do broker | `rabbitmq:15692`, caminho `/metrics` (job sugerido: `rabbitmq`) |
| Alvo do coletor de logs | `log-shipper:2020`, caminho `/api/v2/metrics/prometheus` (job sugerido: `rabbitmq-log-shipper`) |
| Rede | `rabbitmq-metrics` (nome fixo, `internal: true`, criada pelo compose deste projeto) |
| No host | `http://127.0.0.1:15692/metrics` (publicada só em loopback) |

Na F01: o Prometheus do `grafana` entra nessa rede como `external` (mesmo padrão de `metrics`/`probe`), em
`prometheus/docker-compose.metrics.yml`:

```yaml
services:
  prometheus:
    networks: [metrics, rabbitmq-metrics]
networks:
  rabbitmq-metrics:
    name: rabbitmq-metrics
    external: true
```

Alvos: novo arquivo em `prometheus/targets/` (file_sd) ou jobs em `prometheus/prometheus.yml`:

```yaml
- job_name: rabbitmq
  static_configs:
    - targets: ["rabbitmq:15692"]
      labels: {project: rabbitmq}
- job_name: rabbitmq-log-shipper
  metrics_path: /api/v2/metrics/prometheus
  static_configs:
    - targets: ["log-shipper:2020"]
      labels: {project: rabbitmq}
```

Pré-requisito: o broker de pé (`docker compose up -d`) para a rede existir. Os dois serviços ficam na `rabbitmq-metrics`
(o coletor entra nela só para expor o backlog; ele não publica portas).

## 2. Dashboards oficiais (JSON baixado por revisão fixa)

Pasta sugerida: `provisioning/dashboards/rabbitmq/`, datasource uid `prometheus`, passar no `lint-dashboards.sh`.

| Dashboard | ID | Revisão | Download |
|---|---|---|---|
| RabbitMQ-Overview | 10991 | 15 | `https://grafana.com/api/dashboards/10991/revisions/15/download` |
| Erlang-Distribution | 11352 | 10 | `https://grafana.com/api/dashboards/11352/revisions/10/download` |
| Erlang-Memory-Allocators | 11350 | 8 | `https://grafana.com/api/dashboards/11350/revisions/8/download` |

Revalidar as revisões no grafana.com ao implementar. Estes dashboards esperam as variáveis de cluster/nó do
`rabbitmq_identity_info` (já exposto) e, para detalhes por fila, as métricas por objeto (já habilitadas).

## 3. Alertas propostos (pasta `rabbitmq`, labels `project: rabbitmq` e `severity`)

Métricas conferidas no broker: `rabbitmq_queue_messages_ready`, `rabbitmq_queue_messages_unacked`,
`rabbitmq_queue_consumers` (todas com rótulos `vhost`, `queue`), `rabbitmq_process_resident_memory_bytes`,
`rabbitmq_resident_memory_limit_bytes`, `rabbitmq_disk_space_available_bytes`, `rabbitmq_disk_space_available_limit_bytes`,
`rabbitmq_alarms_memory_used_watermark`, `rabbitmq_alarms_free_disk_space_watermark`. Do coletor:
`fluentbit_storage_fs_chunks`, `fluentbit_output_retries_total`, `fluentbit_output_dropped_records_total`
(rótulo `name="gelf.0"` nas de saída).

| Alerta | Expressão PromQL | for | severity |
|---|---|---|---|
| Fila crescendo | `deriv(rabbitmq_queue_messages_ready{queue!~".*\\.dlq"}[15m]) > 0 and rabbitmq_queue_messages_ready{queue!~".*\\.dlq"} > 100` | 15m | warning |
| Fila com mensagens e sem consumidor | `rabbitmq_queue_messages_ready{queue!~".*\\.dlq"} > 0 and on(vhost, queue) rabbitmq_queue_consumers == 0` | 10m | warning |
| Memória alta (> 80% do limite do broker) | `rabbitmq_process_resident_memory_bytes / rabbitmq_resident_memory_limit_bytes > 0.8` | 5m | warning |
| Alarme de memória ativo | `rabbitmq_alarms_memory_used_watermark == 1` | 0m | critical |
| Disco perto do limite | `rabbitmq_disk_space_available_bytes < 2 * rabbitmq_disk_space_available_limit_bytes` | 10m | warning |
| Alarme de disco ativo | `rabbitmq_alarms_free_disk_space_watermark == 1` | 0m | critical |
| DLQ não vazia | `sum by (vhost, queue) (rabbitmq_queue_messages_ready{queue=~".*\\.dlq"}) > 0` | 5m | warning |
| Broker fora | `up{job="rabbitmq"} == 0` | 2m | critical |
| Backlog do coletor de logs | `fluentbit_storage_fs_chunks{job="rabbitmq-log-shipper"} > 0` | 10m | warning |
| Coletor descartando registros | `increase(fluentbit_output_dropped_records_total{job="rabbitmq-log-shipper"}[15m]) > 0` | 0m | critical |

Observações:

- A memória do broker (`mem_limit: 1g`, watermark absoluto de 600 MiB) tem o limite exposto em
  `rabbitmq_resident_memory_limit_bytes` (hoje 629145600); por isso a razão acompanha o watermark e não o limite do container.
- O backlog do coletor fica > 0 por instantes em operação normal (chunks de 1 s a caminho); o `for: 10m` evita ruído.
  Com o Graylog fora, ele cresce até o teto do buffer (`storage.total_limit_size 200M`).
- "Coletor descartando registros": `fluentbit_output_dropped_records_total` sobe quando o teto do buffer em disco (`storage.total_limit_size 200M`) descarta registros (confirmado em teste); é a única forma de perda do coletor e por isso é `critical`. Com o destino fora e abaixo do teto nada é descartado (só o backlog cresce).
- Sem `noDataState`: `up == 0` deve tratar "sem dados" como problema (`noDataState: Alerting`) apenas para o broker.
- Os nomes de DLQ seguem a convenção `<app>-consumer.<fila>.dlq` (ex.: `smoke-consumer.ping.dlq`).

## 4. Logs no Graylog (tarefa F02, referência)

O coletor envia GELF TCP para `graylog:12201` pela rede `observability` com os campos `_time`, `level` (sempre numérico, syslog: error=3, warning=4, notice=5, info=6, convertido pelo filtro
`config/fluent-bit/level.lua`; o log do broker traz o nível como texto), `short_message` e `_service_name=rabbitmq`/`_tag=rabbitmq`, `host=rabbitmq`. Até a F02, as mensagens caem no stream
padrão. O pipeline `level` do Graylog não precisa converter texto: o campo já chega numérico. Proposta para o `graylog/provisioning/provision.sh`: stream "RabbitMQ - Infra" por `service_name:rabbitmq`,
retenção própria e alertas para erros (`level <= 3`) e rajadas de `failed to authenticate`/`access denied`.
