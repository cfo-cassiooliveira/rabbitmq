#!/usr/bin/env bash
# Teste ponta a ponta REAL: broker -> arquivo JSON -> Fluent Bit (log-shipper) -> GELF TCP -> Graylog do ../graylog.
# SÓ LOCAL: o runner do CI não tem Graylog, por isso este script não entra no CI (o CI prova o fallback com o
# gelf-sink descartável, seção n do smoke). Não reinicia nem recria o broker, o coletor ou o Graylog: gera eventos
# reais no broker já no ar (logins recusados de usuários inexistentes e fictícios "e2e-nobody-<run>-*", via AMQP com a
# imagem do cliente de smoke e via HTTP no management) e consulta a API de busca do Graylog até achá-los.
# Prova: stream "RabbitMQ - Infra" e nenhum outro, service_name/tag/source, nível numérico 3/4 e level_name coerentes,
# texto real do RabbitMQ 4.3 (2 linhas por tentativa), senha ausente, a regra 15 do Graylog não rebaixa erro com
# "[info]" vindo do cliente e as consultas dos alertas do RabbitMQ contam como esperado (1 por tentativa; 0 erros).
# Requer: broker e log-shipper no ar, ../graylog no ar e provisionado, .env dos dois projetos. Nada sensível é impresso
# (a senha do Graylog é lida do ../graylog/.env só para a variável e vai ao curl pelo stdin, não pela linha de comando).
# Uso: ./scripts/e2e-graylog.sh   (GRAYLOG_DIR, GRAYLOG_URL, E2E_TIMEOUT_SECONDS, E2E_ATTEMPTS opcionais)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
GRAYLOG_DIR="${GRAYLOG_DIR:-../graylog}"
GRAYLOG_URL="${GRAYLOG_URL:-http://127.0.0.1:9000}"
MANAGEMENT_URL="http://127.0.0.1:15672/api/overview"
TIMEOUT_SECONDS="${E2E_TIMEOUT_SECONDS:-180}"
POLL_SECONDS=5
ATTEMPTS="${E2E_ATTEMPTS:-3}"
RUN_ID="e2e$(date +%s)${RANDOM}"
USER_PREFIX="e2e-nobody-${RUN_ID}"
# Senha errada sem o RUN_ID: a busca por ela tem de voltar vazia (prova que senha não vai para o log).
WRONG_PASSWORD="wrong${RANDOM}${RANDOM}x${RANDOM}"
CHECKER="tests/e2e/graylog_check.py"

failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
die() { echo "FAIL  $*"; echo; echo "FAILED: e2e aborted."; exit 1; }
# Git Bash (Windows): sem conversão de caminhos só nos comandos do docker (o curl do host precisa dela).
dc() { MSYS_NO_PATHCONV=1 docker compose "$@"; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

graylog_password="$(grep -E '^GRAYLOG_ROOT_PASSWORD=' "${GRAYLOG_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
[[ -n "$graylog_password" ]] || die "GRAYLOG_ROOT_PASSWORD not found in ${GRAYLOG_DIR}/.env"
# Chamada à API do Graylog: credencial pelo stdin (config do curl); demais argumentos repassados; corpo na saída.
graylog_api() {
  printf 'user = "admin:%s"\n' "$graylog_password" | curl -sS --max-time 15 --fail-with-body -K - \
    -H 'X-Requested-By: rabbitmq-e2e' -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"
}
# Busca de mensagens (corpo JSON pequeno, sem segredo) com a resposta gravada em arquivo (nunca como argumento).
search_to_file() { graylog_api -X POST --data-binary "$1" "${GRAYLOG_URL}/api/search/messages" > "$2"; }
search_body() { # <consulta>
  printf '{"query":%s,"timerange":{"type":"relative","range":900},"size":500,"fields":["message","level","level_name","streams","service_name","tag","source","time"]}' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
}
# Roda o verificador Python na imagem do smoke, sem rede e sem privilégios; JSON pelo stdin.
checker() { # <arquivo JSON> <subcomando> [args...]
  local input="$1"; shift
  MSYS_NO_PATHCONV=1 docker run --rm -i --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 128m --entrypoint python "$smoke_image" -c "$(cat "$CHECKER")" "$@" < "$input"
}
started_at() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- pré-condições (sem subir nada)
echo "== preconditions (run ${RUN_ID}) =="
broker_cid="$(dc ps -q rabbitmq 2>/dev/null)"; shipper_cid="$(dc ps -q log-shipper 2>/dev/null)"
[[ -n "$broker_cid" && -n "$shipper_cid" ]] || die "broker or log-shipper is not running (this script never starts them)"
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$broker_cid")" == "healthy" ]] || die "broker is not healthy"
[[ "$(docker inspect -f '{{.State.Status}}' "$shipper_cid")" == "running" ]] || die "log-shipper is not running"
broker_started="$(started_at "$broker_cid")"; shipper_started="$(started_at "$shipper_cid")"
lbstatus="$(curl -s --max-time 5 "${GRAYLOG_URL}/api/system/lbstatus")"
[[ "$lbstatus" == "ALIVE" ]] || die "Graylog is not reachable/alive at ${GRAYLOG_URL} (got '${lbstatus}'); start ../graylog first"
graylog_api "${GRAYLOG_URL}/api/system" > /dev/null || die "Graylog API rejected the credentials from ${GRAYLOG_DIR}/.env"
MSYS_NO_PATHCONV=1 timeout 300 docker compose --profile smoke build -q smoke > /dev/null 2>&1 || die "smoke client image build failed"
smoke_image="$(dc --profile smoke config --images 2>/dev/null | grep -- "-smoke$" | head -1)"
[[ -n "$smoke_image" ]] || die "smoke client image name not found"
pass "broker healthy, log-shipper running, Graylog ALIVE and API authenticated"

# ---------------------------------------------------------------- eventos reais no broker
echo "== real events =="
http_ok=0
for i in $(seq 1 "$ATTEMPTS"); do
  status="$(printf 'user = "%s:%s"\n' "${USER_PREFIX}-http-${i}" "$WRONG_PASSWORD" \
    | curl -s --max-time 10 -o /dev/null -w '%{http_code}' -K - "$MANAGEMENT_URL")"
  [[ "$status" == "401" ]] && http_ok=$((http_ok + 1))
done
if [[ "$http_ok" == "$ATTEMPTS" ]]; then pass "management refused ${ATTEMPTS} logins (HTTP 401)"; else fail "management refused ${http_ok}/${ATTEMPTS} logins"; fi

# Usuários AMQP: um por tentativa e a sonda de nível, cujo nome traz "[info]" (texto vindo do cliente).
amqp_users=()
for i in $(seq 1 "$ATTEMPTS"); do amqp_users+=("${USER_PREFIX}-amqp-${i}"); done
amqp_users+=("${USER_PREFIX}-lvl-[info]")
amqp_code='
import sys, pika
from pika import exceptions as pe
refused = 0
for user in sys.argv[2:]:
    params = pika.ConnectionParameters(host="rabbitmq", virtual_host="dev", connection_attempts=1, socket_timeout=5,
                                       credentials=pika.PlainCredentials(user, sys.argv[1]))
    try:
        pika.BlockingConnection(params).close()
    except (pe.ProbableAuthenticationError, pe.ProbableAccessDeniedError):
        refused += 1
print(refused)
'
# --no-deps: nunca toca o broker no ar (sem recriar nem reiniciar dependências).
amqp_refused="$(timeout 120 docker compose --profile smoke run --rm --no-deps -T --entrypoint python smoke -c "$amqp_code" \
  "$WRONG_PASSWORD" "${amqp_users[@]}" < /dev/null 2>/dev/null | tail -1)"
if [[ "$amqp_refused" == "${#amqp_users[@]}" ]]; then pass "AMQP refused ${#amqp_users[@]} logins (${ATTEMPTS} + level probe)"; else fail "AMQP refused '${amqp_refused}'/${#amqp_users[@]} logins"; fi

# ---------------------------------------------------------------- espera a chegada no Graylog
echo "== Graylog search (timeout ${TIMEOUT_SECONDS}s) =="
expected=$((2 * (ATTEMPTS + ${#amqp_users[@]})))
found=0
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if search_to_file "$(search_body "\"${RUN_ID}\"")" "$work/run.json"; then
    found="$(checker "$work/run.json" count)"
    [[ "$found" -ge "$expected" ]] && break
  fi
  sleep "$POLL_SECONDS"
done
if [[ "$found" -ge "$expected" ]]; then pass "Graylog indexed the ${expected} messages of this run"; else fail "Graylog has ${found}/${expected} messages of this run after ${TIMEOUT_SECONDS}s (log-shipper backlog: ./scripts/logs-fallback-check.sh)"; fi
# Uma releitura curta pega eventuais duplicatas atrasadas antes das verificações.
sleep "$POLL_SECONDS"; search_to_file "$(search_body "\"${RUN_ID}\"")" "$work/run.json" || fail "Graylog search failed"
checker "$work/run.json" check "$RUN_ID" "$ATTEMPTS" "$ATTEMPTS" "$WRONG_PASSWORD" > "$work/check.txt"; cat "$work/check.txt"
failures=$((failures + $(grep -c "^FAIL  " "$work/check.txt")))
grep -q "^PASS  " "$work/check.txt" || fail "message checks produced no PASS line"

search_to_file "$(search_body "\"${WRONG_PASSWORD}\"")" "$work/password.json" || fail "Graylog search failed"
if [[ "$(checker "$work/password.json" count)" == "0" ]]; then pass "searching Graylog for the wrong password finds nothing"; else fail "the wrong password was found in Graylog"; fi

# ---------------------------------------------------------------- consultas dos alertas (provisionadas no ../graylog)
echo "== alert queries =="
graylog_api "${GRAYLOG_URL}/api/events/definitions?per_page=200" > "$work/definitions.json" || fail "could not read event definitions"
alert_count() { # <título do alerta>: quantas mensagens deste run a consulta do alerta acha no stream dele
  checker "$work/definitions.json" alert-search "$1" "$RUN_ID" > "$work/alert-body.json" || { echo -1; return; }
  graylog_api -X POST --data-binary "$(cat "$work/alert-body.json")" "${GRAYLOG_URL}/api/search/messages" > "$work/alert.json" \
    && checker "$work/alert.json" count || echo -1
}
attempts_total=$((ATTEMPTS + ${#amqp_users[@]}))
login_count="$(alert_count "RabbitMQ - Falhas de login em massa")"
if [[ "$login_count" == "$attempts_total" ]]; then pass "alert 'RabbitMQ - Falhas de login em massa' counts 1 per refused login (${login_count})"; else fail "alert 'RabbitMQ - Falhas de login em massa' counted ${login_count}, expected ${attempts_total} (1 per attempt)"; fi
error_count="$(alert_count "RabbitMQ - Erros no broker")"
if [[ "$error_count" == "0" ]]; then pass "alert 'RabbitMQ - Erros no broker' ignores refused logins (0)"; else fail "alert 'RabbitMQ - Erros no broker' counted ${error_count} refused-login lines, expected 0"; fi

# ---------------------------------------------------------------- nada foi reiniciado
echo "== no restart =="
if [[ "$(started_at "$broker_cid")" == "$broker_started" && "$(started_at "$shipper_cid")" == "$shipper_started" ]]; then
  pass "broker and log-shipper were not restarted (StartedAt unchanged)"
else
  fail "broker or log-shipper StartedAt changed during the run"
fi

echo
if [[ "$failures" -eq 0 ]]; then echo "OK: e2e ${RUN_ID} passed."; else echo "FAILED: ${failures} check(s) in e2e ${RUN_ID}."; exit 1; fi
