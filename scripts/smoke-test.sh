#!/usr/bin/env bash
# Smoke test do broker (incremental: cada tarefa acrescenta suas seções). Requer o .env e o broker no ar.
# Uso: ./scripts/smoke-test.sh
# Seções atuais: (a) portas, healthcheck, UI/API; (b) guest negado; (c) render das definitions; (d) AMQP (pika);
# (e) provisionador idempotente; (j) fluxo de mudança do template (render, restart, provisionador).
# (l) métricas Prometheus; (m) logs em arquivo e coletor; (n) fallback de logs com gelf-sink descartável
# (tests/smoke/logs-fallback.sh, ~2 min; SKIP_LOGS_FALLBACK=1 pula). Bordas em scripts/smoke-edge.sh.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# Git Bash (Windows): impede a conversão de caminhos como /var/log em argumentos do docker.
export MSYS_NO_PATHCONV=1
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
admin_password="$(env_value RABBITMQ_ADMIN_PASSWORD)"
smoke_password="$(env_value RABBITMQ_SMOKE_APP_PASSWORD)"
api_url="http://127.0.0.1:15672/api"
# O segredo vai por arquivo de config do curl (stdin), não pela linha de comando.
http_status() { printf 'user = "%s:%s"\n' "$1" "$2" | curl -s -o /dev/null -w '%{http_code}' -K - "${api_url}$3"; }
wait_api() { for _ in $(seq 1 60); do [[ "$(http_status admin "$admin_password" /overview)" == "200" ]] && return 0; sleep 2; done; return 1; }

# ---------------------------------------------------------------- (a) portas, healthcheck, UI/API
echo "== (a) broker =="
cid="$(docker compose ps -q rabbitmq)"
[[ -n "$cid" ]] || { echo "broker is not running (docker compose up -d)"; exit 1; }
check "broker healthcheck is healthy" test "$(docker inspect -f '{{.State.Health.Status}}' "$cid")" = "healthy"
check "ports published only on 127.0.0.1" \
  test -z "$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}{{"\n"}}{{end}}{{end}}' "$cid" | grep -v '^127\.0\.0\.1$' | grep -v '^$')"
check "mem_limit is 1g" test "$(docker inspect -f '{{.HostConfig.Memory}}' "$cid")" = "1073741824"
# no-new-privileges ligado e o broker (beam.smp) rodando como o usuário rabbitmq (uid 999) depois do rebaixamento do entrypoint.
# Confere só o PID 1: o entrypoint faz exec do gosu até o beam.smp do broker. As CLIs (healthcheck e `exec` dos
# smokes) sobem outras VMs Erlang, também chamadas beam.smp e como root, que não podem entrar na verificação.
check "no-new-privileges is set on the broker" bash -c 'docker inspect -f "{{.HostConfig.SecurityOpt}}" "$0" | grep -q "no-new-privileges:true"' "$cid"
check "broker process (PID 1, beam.smp) has NoNewPrivs=1 and runs as uid 999" docker compose exec -T rabbitmq bash -c '
  status=/proc/1/status
  grep -q "^Name:[[:space:]]*beam.smp$" "$status" &&
    grep -q "^NoNewPrivs:[[:space:]]*1$" "$status" &&
    grep -qE "^Uid:([[:space:]]+999){4}$" "$status"'
check "management API returns 200 for admin" test "$(http_status admin "$admin_password" /overview)" = "200"
check "workspace-messaging network exists" ./scripts/messaging-network.sh

# ---------------------------------------------------------------- (b) guest negado
echo "== (b) guest =="
check "guest is rejected by the API (HTTP 401)" test "$(http_status guest guest /overview)" = "401"
check "guest does not exist in the broker" bash -c "! docker compose exec -T rabbitmq rabbitmqctl -q list_users | cut -f1 | grep -qx guest"
check "guest is rejected for AMQP (authenticate_user)" bash -c "! docker compose exec -T rabbitmq rabbitmqctl -q authenticate_user guest guest"
check "admin authenticates" docker compose exec -T rabbitmq rabbitmqctl -q authenticate_user admin "$admin_password"
check "smoke-app authenticates" docker compose exec -T rabbitmq rabbitmqctl -q authenticate_user smoke-app "$smoke_password"

# ---------------------------------------------------------------- (c) definitions
echo "== (c) definitions =="
defs="$(printf 'user = "admin:%s"\n' "$admin_password" | curl -s -K - "${api_url}/definitions/dev")"
check "smoke exchange and queues are present" bash -c 'grep -q "smoke.events" <<<"$0" && grep -q "smoke-consumer.ping.dlq" <<<"$0"' "$defs"
check "smoke-dlx policy is present" grep -q '"smoke-dlx"' <<<"$defs"
check "smoke queues are quorum" test "$(grep -o '"x-queue-type": *"quorum"' <<<"$defs" | wc -l)" -ge 2
check "deterministic render (RENDER_SALT_HEX) is stable" bash -c '
  cp definitions/definitions.json /tmp/defs.keep.$$ &&
  RENDER_SALT_HEX=00112233 ./scripts/render-definitions.sh >/dev/null && cp definitions/definitions.json /tmp/defs.a.$$ &&
  RENDER_SALT_HEX=00112233 ./scripts/render-definitions.sh >/dev/null && cmp -s definitions/definitions.json /tmp/defs.a.$$;
  rc=$?; cp /tmp/defs.keep.$$ definitions/definitions.json; rm -f /tmp/defs.*.$$; exit $rc'
check "definitions.json has no placeholders" bash -c "! grep -q '__[A-Z_]*__' definitions/definitions.json"


# ---------------------------------------------------------------- (d) AMQP ponta a ponta (pika em container descartável)
echo "== (d) AMQP end to end =="
api_json() { printf 'user = "admin:%s"\n' "$admin_password" | curl -s -K - "${api_url}$1"; }
# Roda uma fase do cliente (timeout externo, sem TTY), imprime PASS/FAIL e reprova por FAIL, saída != 0 ou fase sem PASS.
run_phase() {
  local out rc
  out="$(timeout 240 docker compose --profile smoke run --rm -T smoke "$1" 2>&1)"; rc=$?
  grep -E '^(PASS|FAIL)  ' <<<"$out"
  failures=$((failures + $(grep -c '^FAIL  ' <<<"$out")))
  if ! grep -q '^PASS  ' <<<"$out"; then fail "AMQP phase $1 produced no PASS line"; fi
  if [[ "$rc" != "0" ]] && ! grep -q '^FAIL  ' <<<"$out"; then fail "AMQP phase $1 exited with code $rc"; fi
}
# Remove filas temporárias órfãs de execuções interrompidas (o cliente não tem acesso à API).
api_json "/queues/dev" | grep -o '"name":"smoke-consumer\.t[^"]*"' | cut -d'"' -f4 | while read -r orphan; do
  printf 'user = "admin:%s"\n' "$admin_password" | curl -s -o /dev/null -X DELETE -K - "${api_url}/queues/dev/${orphan}"
done
for queue in smoke-consumer.ping smoke-consumer.ping.dlq; do
  check "queue ${queue} is quorum (management API)" bash -c 'grep -q "\"type\":\"quorum\"" <<<"$0"' "$(api_json "/queues/dev/${queue}")"
done
docker compose --profile smoke build -q smoke >/dev/null 2>&1 || fail "smoke client image build failed"
run_phase main
# A API atualiza estatísticas a cada ~5 s: espera um ciclo antes de ler as mensagens sem ack.
sleep 6
check "no unacknowledged messages remain after the AMQP phase (management API)" bash -c \
  'for q in smoke-consumer.ping smoke-consumer.ping.dlq; do grep -q "\"messages_unacknowledged\":0" <<<"$(printf "user = \"admin:%s\"\n" "$0" | curl -s -K - "$1/queues/dev/$q")" || exit 1; done' "$admin_password" "$api_url"
# Persistência e reconexão: publica, reinicia o broker, reconecta e consome.
run_phase persist-publish
started_before="$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
if docker compose restart rabbitmq >/dev/null 2>&1 && wait_api; then pass "broker restart completed and API is back"; else fail "broker restart failed or API did not come back"; fi
started_after="$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
check "container was really restarted (StartedAt changed)" test "$started_before" != "$started_after"
run_phase persist-verify
run_phase cleanup

# ---------------------------------------------------------------- (e) idempotência do provisionador
echo "== (e) provisioner =="
run1="$(docker compose run --rm provisioner 2>&1)"; rc1=$?
run2="$(docker compose run --rm provisioner 2>&1)"; rc2=$?
check "provisioner runs (1st)" test "$rc1" = "0"
check "provisioner runs (2nd)" test "$rc2" = "0"
check "2nd run changes nothing (no removals)" bash -c '! grep -q "removed" <<<"$0"' "$run2"
check "state-digest is the same in both runs" test "$(grep -o 'state-digest=[0-9a-f]*' <<<"$run1")" = "$(grep -o 'state-digest=[0-9a-f]*' <<<"$run2")"
check "guest stays removed after the provisioner" test "$(http_status guest guest /overview)" = "401"

# ---------------------------------------------------------------- (j) fluxo de mudança do template
echo "== (j) template change flow =="
# Fluxo documentado: editar o template -> render -> restart do broker (import) -> provisionador.
started_before="$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
./scripts/render-definitions.sh >/dev/null
if docker compose restart rabbitmq >/dev/null 2>&1 && wait_api; then pass "render + restart completed and API is back"; else fail "render + restart failed or API did not come back"; fi
check "container was really restarted after the render (StartedAt changed)" test "$started_before" != "$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
check "after render + restart the broker is healthy and users exist" bash -c \
  'docker compose exec -T rabbitmq rabbitmqctl -q list_users | cut -f1 | grep -qx smoke-app'
check "provisioner passes after render + restart" docker compose run --rm provisioner
check "admin still authenticates after the re-render" docker compose exec -T rabbitmq rabbitmqctl -q authenticate_user admin "$admin_password"

# ---------------------------------------------------------------- (l) métricas Prometheus
echo "== (l) metrics =="
# Logo após o restart/provisionamento o coletor de métricas ainda não emitiu as séries por fila (e a 1ª leitura pode vir
# vazia): espera até 60 s pela série da fila de smoke antes de avaliar, em vez de uma leitura única.
# A saída (~180 KB) vai para um arquivo: passá-la como argumento de `bash -c` estoura o limite de 128 KiB por argumento do
# Linux (MAX_ARG_STRLEN) e reprovava os checks no CI, sem aparecer no Windows.
metrics_file="$(mktemp)"
for _ in $(seq 1 30); do
  curl -s --max-time 5 http://127.0.0.1:15692/metrics > "$metrics_file"
  if grep -q '^rabbitmq_queue_messages_ready{vhost="dev",queue="smoke-consumer.ping"}' "$metrics_file"; then break; fi
  sleep 2
done
check "/metrics on 15692 responds 200" test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:15692/metrics)" = "200"
check "/metrics has per-queue metrics (ready, unacked, consumers) for the smoke queue" bash -c \
  'grep -q "^rabbitmq_queue_messages_ready{vhost=\"dev\",queue=\"smoke-consumer.ping\"}" "$0" && grep -q "^rabbitmq_queue_messages_unacked{vhost=\"dev\",queue=\"smoke-consumer.ping.dlq\"}" "$0" && grep -q "^rabbitmq_queue_consumers{" "$0"' "$metrics_file"
check "/metrics has memory and disk metrics" bash -c \
  'grep -q "^rabbitmq_process_resident_memory_bytes " "$0" && grep -q "^rabbitmq_resident_memory_limit_bytes " "$0" && grep -q "^rabbitmq_disk_space_available_bytes " "$0" && grep -q "^rabbitmq_disk_space_available_limit_bytes " "$0"' "$metrics_file"
rm -f "$metrics_file"
check "port 15692 is published only on 127.0.0.1" \
  test "$(docker inspect -f '{{range $b := index .NetworkSettings.Ports "15692/tcp"}}{{$b.HostIp}} {{end}}' "$cid" | xargs)" = "127.0.0.1"
check "rabbitmq-metrics network is internal and has the broker" bash -c \
  'test "$(docker network inspect rabbitmq-metrics -f "{{.Internal}}")" = "true" && docker network inspect rabbitmq-metrics -f "{{range .Containers}}{{.Name}} {{end}}" | grep -q rabbitmq-rabbitmq-1'

# ---------------------------------------------------------------- (m) logs em arquivo e coletor
echo "== (m) logs =="
# O log passa de 1 MB: vai para arquivo temporário (como argumento de linha de comando estoura o limite do Windows e trava).
log_file="$(mktemp)"; trap 'rm -f "$log_file"' EXIT
timeout 60 docker compose exec -T rabbitmq cat /var/log/rabbitmq/rabbit.log > "$log_file" 2>/dev/null
check "broker writes the JSON log file" bash -c 'head -1 "$0" | grep -q "^{\"time\":\".*\"level\":\".*\"msg\":\""' "$log_file"
check "rotation is configured (10 MiB x 5, compressed, json)" bash -c \
  'c=./config/rabbitmq.conf; grep -q "^log.file.rotation.size = 10485760" $c && grep -q "^log.file.rotation.count = 5" $c && grep -q "^log.file.rotation.compress = true" $c && grep -q "^log.file.formatter = json" $c'
check "console log is kept (json)" bash -c 'grep -q "^log.console = true" ./config/rabbitmq.conf && grep -q "^log.console.formatter = json" ./config/rabbitmq.conf'
shipper_cid="$(docker compose ps -q log-shipper)"
check "log-shipper is running and its API answers (uptime); liveness probed from outside, the image is distroless" bash -c '[[ "$(docker inspect -f "{{.State.Status}}" "$0")" == "running" ]] && ./scripts/shipper-api.sh /api/v1/uptime | grep -q uptime_sec' "$shipper_cid"
check "only the log-shipper is on the observability network" bash -c \
  'n="$(docker network inspect observability -f "{{range .Containers}}{{.Name}} {{end}}")"; grep -q rabbitmq-log-shipper-1 <<<"$n" && ! grep -q rabbitmq-rabbitmq-1 <<<"$n"'
check "logs-fallback-check.sh lists local logs and backlog" bash -c './scripts/logs-fallback-check.sh | grep -q "^backlog_chunks="'
check "log file was read (not empty)" test -s "$log_file"
check "no passwords in the local log file" bash -c '! grep -qF -e "$0" -e "$1" "$2"' "$admin_password" "$smoke_password" "$log_file"

# ---------------------------------------------------------------- (n) fallback de logs (gelf-sink descartável)
if [[ "${SKIP_LOGS_FALLBACK:-0}" == "1" ]]; then
  echo "== (n) logs fallback: skipped (SKIP_LOGS_FALLBACK=1) =="
else
  if ./tests/smoke/logs-fallback.sh; then pass "logs fallback smoke (tests/smoke/logs-fallback.sh)"; else fail "logs fallback smoke (tests/smoke/logs-fallback.sh)"; fi
fi


echo
if [[ "$failures" -eq 0 ]]; then echo "OK: all tests passed."; else echo "FAILED: ${failures} test(s)."; exit 1; fi
