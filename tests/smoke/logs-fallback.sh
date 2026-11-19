#!/usr/bin/env bash
# Smoke do fallback de logs (T08): com o destino GELF fora, os logs do broker ficam no arquivo local e no buffer do
# coletor e chegam ao destino quando ele volta, inclusive após reiniciar o coletor. Usa um gelf-sink DESCARTÁVEL e uma
# cópia do coletor (log-shipper-test, profile logs-test): não toca o Graylog real nem o log-shipper real.
# Eventos marcados: tentativas de login de usuários inexistentes "fbk<run>n<i>" na API (viram linhas de log no broker).
# Uso: ./tests/smoke/logs-fallback.sh      Requer o .env e o broker no ar. Limpa tudo o que cria.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
export MSYS_NO_PATHCONV=1
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

EVENTS=20
run="$(date +%s)$RANDOM"
prefix="fbk${run}n"
dummy_password="not-a-real-password-${run}"
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
admin_password="$(env_value RABBITMQ_ADMIN_PASSWORD)"
smoke_password="$(env_value RABBITMQ_SMOKE_APP_PASSWORD)"
# Todo comando docker tem timeout: um daemon ou container preso não pode travar o smoke (wait_for repete a condição).
compose() { timeout 120 docker compose --profile logs-test "$@"; }

cleanup() {
  compose rm -sf log-shipper-test gelf-sink >/dev/null 2>&1
  timeout 30 docker volume rm rabbitmq_fluentbit-buffer-test rabbitmq_gelf-sink-data >/dev/null 2>&1
}
trap cleanup EXIT

# Gera um evento marcado: o login falho de um usuário inexistente é registrado pelo broker (a senha usada é descartável).
emit() { printf 'user = "%s%s:%s"\n' "$prefix" "$1" "$dummy_password" | curl -s --max-time 10 -o /dev/null -K - http://127.0.0.1:15672/api/overview; }
broker_log() { compose exec -T rabbitmq cat /var/log/rabbitmq/rabbit.log; }
sink_data() { compose exec -T gelf-sink cat /data/received.jsonl 2>/dev/null; }
# Quantos marcadores distintos (dos eventos 1..N) existem na entrada.
distinct_markers() { grep -o "${prefix}[0-9]*" | sort -u | wc -l; }
backlog() { SHIPPER=log-shipper-test timeout 90 ./scripts/logs-fallback-check.sh 2>/dev/null | grep -o '^backlog_chunks=[0-9]*' | cut -d= -f2; }
# Espera a condição (comando) por até $1 segundos.
wait_for() { local limit="$1"; shift; for _ in $(seq 1 "$limit"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
shipper_healthy() { SHIPPER=log-shipper-test timeout 60 ./scripts/shipper-api.sh /api/v1/uptime | grep -q uptime_sec; }
sink_has() { [[ "$(sink_data | distinct_markers)" -ge "$1" ]]; }
backlog_positive() { [[ "$(backlog)" -gt 0 ]]; }
backlog_zero() { [[ "$(backlog)" == "0" ]]; }

[[ -n "$(docker compose ps -q rabbitmq)" ]] || { echo "broker is not running (docker compose up -d)"; exit 1; }
./scripts/observability-network.sh >/dev/null || { echo "could not ensure the observability network"; exit 1; }
cleanup

echo "== (n) logs fallback (disposable gelf-sink; the real Graylog is not touched) =="
compose up -d --build gelf-sink log-shipper-test >/dev/null 2>&1 || { fail "could not start gelf-sink and log-shipper-test"; exit 1; }
check "test collector is up and its API answers" wait_for 60 shipper_healthy

# (1) destino no ar: o evento chega ao arquivo local e ao destino
emit 0
check "event reaches the local log file" wait_for 20 bash -c "grep -q '${prefix}0' <(timeout 30 docker compose exec -T rabbitmq cat /var/log/rabbitmq/rabbit.log)"
check "event reaches the sink while it is up" wait_for 40 bash -c "grep -q '${prefix}0' <(timeout 30 docker compose --profile logs-test exec -T gelf-sink cat /data/received.jsonl)"
check "backlog drains to 0 while the sink is up" wait_for 30 backlog_zero

# (2) destino fora: arquivo registra e o coletor acumula backlog
compose stop gelf-sink >/dev/null 2>&1
for i in $(seq 1 "$EVENTS"); do emit "$i"; done
check "all ${EVENTS} events are in the local log file with the sink down" wait_for 20 bash -c "[[ \$(timeout 30 docker compose exec -T rabbitmq cat /var/log/rabbitmq/rabbit.log | grep -o '${prefix}[0-9]*' | sort -u | wc -l) -ge $((EVENTS + 1)) ]]"
check "collector reports backlog > 0 with the sink down" wait_for 30 backlog_positive
check "logs-fallback-check.sh lists the local logs and the backlog" bash -c "SHIPPER=log-shipper-test timeout 90 ./scripts/logs-fallback-check.sh | grep -q 'rabbit.log' && SHIPPER=log-shipper-test timeout 90 ./scripts/logs-fallback-check.sh | grep -q '^backlog_chunks='"

# (3) reinício do coletor com o destino ainda fora: o backlog sobrevive (buffer em disco)
compose restart log-shipper-test >/dev/null 2>&1
check "test collector is up again after the restart (API answers)" wait_for 60 shipper_healthy
check "backlog is still > 0 after restarting the collector with the sink down" wait_for 30 backlog_positive

# (4) destino de volta: todos os marcadores chegam (duplicatas toleradas)
compose start gelf-sink >/dev/null 2>&1
check "all ${EVENTS} marked events (+1 initial) arrive after the sink returns" wait_for 120 sink_has $((EVENTS + 1))
check "backlog drains to 0 after delivery" wait_for 60 backlog_zero

# (5) sem dados sensíveis nos logs (arquivo local e destino)
# Os logs vão para arquivos temporários: passá-los como argumento de linha de comando estoura o limite no Windows
# (o log do broker passa de 1 MB) e travava o teste.
logs_file="$(mktemp)"; sink_file="$(mktemp)"
trap 'rm -f "$logs_file" "$sink_file"; cleanup' EXIT
sink_data > "$sink_file"
{ broker_log; cat "$sink_file"; } > "$logs_file"
check "no admin password in the logs" bash -c '! grep -qF -- "$0" "$1"' "$admin_password" "$logs_file"
check "no smoke-app password in the logs" bash -c '! grep -qF -- "$0" "$1"' "$smoke_password" "$logs_file"
check "no probe password in the logs" bash -c '! grep -qF -- "$0" "$1"' "$dummy_password" "$logs_file"
check "no Authorization header or Basic credentials in the logs" bash -c '! grep -qiE "authorization|basic [A-Za-z0-9+/=]{8,}" "$0"' "$logs_file"
check "sink received only the minimized fields (no pid/file/line)" bash -c '! grep -qE "\"_?(pid|file|line|mfa)\"" "$0"' "$sink_file"
# GELF exige "level" numérico (syslog); uma string (ex.: "error") quebra alertas "level <= 3" e pode ser rejeitada pelo Graylog.
check "sink received only numeric GELF levels" bash -c '! grep -qE "\"level\":\"" "$0"' "$sink_file"
# Regressão do bug "level string em erros": os logins falhos viram registros de erro no broker e precisam chegar como 3.
check "error-level records (failed logins) arrive with numeric level 3" bash -c 'grep -q "\"level\":3" "$0"' "$sink_file"
check "sink received service_name and tag" bash -c 'grep -q "\"_service_name\":\"rabbitmq\"" "$0" && grep -q "\"_tag\":\"rabbitmq\"" "$0"' "$sink_file"

echo
if [[ "$failures" -eq 0 ]]; then echo "OK: logs fallback passed."; else echo "FAILED: ${failures} logs fallback test(s)."; exit 1; fi
