#!/usr/bin/env bash
# Mostra os logs do broker retidos localmente (arquivo JSON com rotação) e o estado/backlog do coletor (log-shipper).
# Somente leitura: não altera nada e não imprime segredos (as linhas passam por um filtro de redação).
# Uso: ./scripts/logs-fallback-check.sh                       (coletor real)
#      SHIPPER=log-shipper-test ./scripts/logs-fallback-check.sh   (coletor de teste do smoke do fallback)
#      LINES=20 ./scripts/logs-fallback-check.sh                (quantas linhas recentes mostrar; padrão 5)
# Saída para máquina: linhas "chave=valor" (backlog_chunks, retries, dropped_records, proc_records, errors).
# E2E opcional com o Graylog real (desligado por padrão, nada deste script o consulta): pesquise "service_name:rabbitmq"
# na UI/API do Graylog com credenciais suas, fornecidas por variável de ambiente; este projeto não lê o .env do graylog.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
shipper="${SHIPPER:-log-shipper}"
lines="${LINES:-5}"
log_dir=/var/log/rabbitmq
export MSYS_NO_PATHCONV=1

# Oculta valores de campos sensíveis caso apareçam (defesa em profundidade; o broker em info não os loga).
redact() { sed -E 's/((password|secret|token|authorization|credential)[a-z_]*"?[:= ]+"?)[^",} ]+/\1***/Ig'; }
json_num() { grep -o "\"$1\":[0-9]*" | head -1 | cut -d: -f2; }

echo "== local logs (broker, ${log_dir}) =="
if [[ -z "$(docker compose ps -q rabbitmq)" ]]; then echo "broker is not running" >&2; exit 1; fi
docker compose exec -T rabbitmq sh -c "ls -l --time-style=long-iso ${log_dir} | tail -n +2 | awk '{print \$5, \$6, \$7, \$8}'"
current="$(docker compose exec -T rabbitmq cat ${log_dir}/rabbit.log 2>/dev/null)"
echo "lines in current file: $(grep -c . <<<"$current")  (error: $(grep -c '"level":"error"' <<<"$current"), warning: $(grep -c '"level":"warning"' <<<"$current"))"
echo "last ${lines} lines (redacted):"
tail -n "$lines" <<<"$current" | cut -c1-240 | redact

echo "== collector (${shipper}) =="
cid="$(docker compose --profile logs-test ps -q "$shipper" 2>/dev/null)"
if [[ -z "$cid" ]]; then echo "${shipper} is not running"; exit 1; fi
echo "container state: $(docker inspect -f '{{.State.Status}}' "$cid") (distroless image: liveness = the API answers below)"
api() { SHIPPER="$shipper" ./scripts/shipper-api.sh "$1"; }
storage="$(api /api/v1/storage)" || { echo "collector API did not answer"; exit 1; }
metrics="$(api /api/v1/metrics)" || { echo "collector API did not answer"; exit 1; }
output="$(grep -o '"output":{.*' <<<"$metrics")"
echo "backlog_chunks=$(json_num fs_chunks <<<"$storage")   # pending chunks on disk (0 = everything delivered)"
echo "proc_records=$(json_num proc_records <<<"$output")   # records delivered to the destination"
echo "errors=$(json_num errors <<<"$output")"
echo "retries=$(json_num retries <<<"$output")"
echo "dropped_records=$(json_num dropped_records <<<"$output")"
echo "destination: $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" | grep -E '^GELF_(HOST|PORT)=' | cut -d= -f2 | paste -sd: -)"
