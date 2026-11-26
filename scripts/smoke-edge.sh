#!/usr/bin/env bash
# Testes de borda da Onda 1 (T01-T04): permissões, render com senhas especiais, provisionador e resiliência.
# Complementa scripts/smoke-test.sh sem a suíte AMQP da T05. Requer o .env e o broker no ar.
# Uso: ./scripts/smoke-edge.sh                      (restart pontual do broker; sem derrubar o volume)
#      SMOKE_DISRUPTIVE=1 ./scripts/smoke-edge.sh   (inclui "docker compose down/up" do broker)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# Git Bash (Windows): impede a conversão de caminhos como /var/log em argumentos do docker.
export MSYS_NO_PATHCONV=1
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
admin_password="$(env_value RABBITMQ_ADMIN_PASSWORD)"
smoke_password="$(env_value RABBITMQ_SMOKE_APP_PASSWORD)"
api_url="http://127.0.0.1:15672/api"
# Os segredos vão por arquivo de config do curl (stdin), nunca pela linha de comando.
api() { printf 'user = "admin:%s"\n' "$admin_password" | curl -s -K - -H 'content-type: application/json' "$@"; }
code() { api -o /dev/null -w '%{http_code}' "$@"; }
code_as() { printf 'user = "%s:%s"\n' "$1" "$2" | curl -s -o /dev/null -w '%{http_code}' -K - "${api_url}$3"; }
# Aguarda a API de management responder 200 (até 120 s).
wait_api() { for _ in $(seq 1 60); do [[ "$(code "${api_url}/overview")" == "200" ]] && return 0; sleep 2; done; return 1; }
broker_users() { docker compose exec -T rabbitmq rabbitmqctl -q list_users | cut -f1; }

[[ -n "$(docker compose ps -q rabbitmq)" ]] || { echo "broker is not running (docker compose up -d)"; exit 1; }

# ---------------------------------------------------------------- (f) permissions (least privilege)
echo "== (f) permissions =="
# Regex de configure/write/read do smoke-app no broker (JSON escapa a barra invertida).
smoke_regex() { api "${api_url}/permissions/dev/smoke-app" | grep -o "\"$1\":\"[^\"]*\"" | cut -d'"' -f4 | sed 's/\\\\/\\/g'; }
allows_prefix_only() {
  local re="$1"
  [[ -n "$re" && "$re" != ".*" ]] || return 1
  grep -Eq "$re" <<<"smoke.events" && grep -Eq "$re" <<<"smoke-consumer.ping" || return 1
  ! grep -Eq "$re" <<<"orders.events" && ! grep -Eq "$re" <<<"amq.gen-1" && ! grep -Eq "$re" <<<"smoke"
}
for kind in configure write read; do
  check "smoke-app: $kind regex allows only the smoke./smoke-consumer. prefix" allows_prefix_only "$(smoke_regex "$kind")"
done
check "smoke-app has no management tag (API 401/403)" test "$(code_as smoke-app "$smoke_password" /overview)" -ge 401
check "smoke-app has permissions only on vhost dev" test "$(api "${api_url}/users/smoke-app/permissions" | grep -o '"vhost":"[^"]*"' | sort -u)" = '"vhost":"dev"'
check "default vhost '/' does not exist (404)" test "$(code "${api_url}/vhosts/%2F")" = "404"
check "admin with wrong password -> 401 on the API" test "$(code_as admin wrong-password /overview)" = "401"
check "unknown user -> 401 on the API" test "$(code_as nobody x /overview)" = "401"
check "smoke-app with wrong password fails authenticate_user" bash -c '! docker compose exec -T rabbitmq rabbitmqctl -q authenticate_user smoke-app wrong-password'
vhost_json="$(api "${api_url}/vhosts/dev")"
check "vhost dev: default_queue_type = quorum" grep -q '"default_queue_type":"quorum"' <<<"$vhost_json"

# ---------------------------------------------------------------- (g) render: bordas (em cópia temporária)
echo "== (g) render =="
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/definitions"
cp scripts/render-definitions.sh "$tmp/scripts/"
fresh_template() { cp definitions/definitions.template.json "$tmp/definitions/"; }
fresh_template
render() { (cd "$tmp" && ./scripts/render-definitions.sh); }
write_env() { printf 'RABBITMQ_ADMIN_PASSWORD=%s\nRABBITMQ_SMOKE_APP_PASSWORD=%s\nRABBITMQ_CADASTRO_APP_PASSWORD=%s\n' "$1" "${2:-zz}" "${3:-yy}" > "$tmp/.env"; }
# Mesma conferência do hash do admin, para o usuário cadastro-app (qualquer usuário do template).
user_hash_matches() {
  local h raw salt expected
  h="$(grep -A1 "\"$1\"" "$tmp/definitions/definitions.json" | grep -o '"password_hash": *"[^"]*"' | cut -d'"' -f4)"
  raw="$(printf '%s' "$h" | openssl base64 -d -A | xxd -p -c100)"; salt="${raw:0:8}"
  expected="$({ printf '%s' "$salt" | xxd -r -p; printf '%s' "$2"; } | openssl dgst -sha256 -binary | xxd -p -c100)"
  [[ "${raw:8}" == "$expected" ]]
}
# Recalcula de forma independente base64(salt[4] + SHA-256(salt + senha)) e compara com o hash do admin.
hash_matches() {
  local h raw salt expected
  h="$(grep -A1 '"admin"' "$tmp/definitions/definitions.json" | grep -o '"password_hash": *"[^"]*"' | cut -d'"' -f4)"
  raw="$(printf '%s' "$h" | openssl base64 -d -A | xxd -p -c100)"; salt="${raw:0:8}"
  expected="$({ printf '%s' "$salt" | xxd -r -p; printf '%s' "$1"; } | openssl dgst -sha256 -binary | xxd -p -c100)"
  [[ "${raw:8}" == "$expected" ]]
}
render_and_verify() { write_env "$1"; render && hash_matches "$1"; }
render_without_env() { rm -f "$tmp/.env" "$tmp/definitions/definitions.json"; render; }
render_twice_differs() {
  write_env a; render || return 1; local first; first="$(cat "$tmp/definitions/definitions.json")"
  render || return 1; [[ "$first" != "$(cat "$tmp/definitions/definitions.json")" ]]
}

if render_without_env >/dev/null 2>&1; then fail "no .env: render should fail"; else
  [[ ! -f "$tmp/definitions/definitions.json" ]] && pass "no .env: render fails and does not create definitions.json" || fail "no .env: file was created"; fi
for pw in 'p@ss w0rd!$x&y|z\1"q#' 'a=b=c' 'ação-ü' ' espaços '; do
  check "correct hash for special password (${#pw} chars)" render_and_verify "$pw"
done
write_env ""
if render >/dev/null 2>&1; then fail "empty password: render should fail"; else pass "empty password: render fails"; fi
write_env a smk 'c@d&e|f\1'
render >/dev/null 2>&1; if user_hash_matches cadastro-app 'c@d&e|f\1' && user_hash_matches smoke-app smk; then pass "cadastro-app and smoke-app hashes match their own passwords"; else fail "cadastro-app/smoke-app hash differs from the .env password"; fi
printf 'RABBITMQ_ADMIN_PASSWORD=a\nRABBITMQ_SMOKE_APP_PASSWORD=b\n' > "$tmp/.env"
if render >/dev/null 2>&1; then fail "missing cadastro password: render should fail"; else pass "missing cadastro-app password in the .env: render fails"; fi
check "rendered definitions keep cadastro-app without management tags and without placeholders" bash -c \
  '! grep -q "__[A-Z_]*__" "$0/definitions/definitions.json" && grep -A4 "\"cadastro-app\"" "$0/definitions/definitions.json" | grep -q "\"tags\": \[\]"' "$tmp"
check "random salt: two renders produce different hashes" render_twice_differs
sed -i 's/__SMOKE_APP_PASSWORD_HASH__/__NEW_PLACEHOLDER__/' "$tmp/definitions/definitions.template.json"
write_env a
if render >/dev/null 2>&1; then fail "unknown placeholder: render should fail"; else pass "unknown placeholder in the template: render fails"; fi
fresh_template
# O compose remove as aspas de valores do .env; o render precisa produzir o mesmo hash que o broker valida.
write_env '"abc"'
render >/dev/null 2>&1; if hash_matches abc; then pass "quoted password in .env: hash of the unquoted password"; else fail "quoted password in .env: hash differs from what compose gives the provisioner"; fi

# generate-env.sh num .env antigo: a senha nova entra em linha própria, mesmo sem quebra de linha final.
cp scripts/generate-env.sh "$tmp/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/scripts/render-definitions.sh"; chmod +x "$tmp/scripts/render-definitions.sh"
printf 'RABBITMQ_ADMIN_PASSWORD=a\nRABBITMQ_SMOKE_APP_PASSWORD=b' > "$tmp/.env"
(cd "$tmp" && ./scripts/generate-env.sh >/dev/null 2>&1)
check "generate-env on an old .env without trailing newline: new password on its own line" bash -c \
  'grep -qx "RABBITMQ_SMOKE_APP_PASSWORD=b" "$0/.env" && grep -q "^RABBITMQ_CADASTRO_APP_PASSWORD=." "$0/.env"' "$tmp"

# ---------------------------------------------------------------- (h) provisionador: bordas
echo "== (h) provisioner =="
api -X PUT -d '{"password":"x","tags":""}' "${api_url}/users/ghost" >/dev/null
api -X PUT -d '{"pattern":"^zz","definition":{"max-length":5},"apply-to":"queues"}' "${api_url}/policies/dev/ghost-pol" >/dev/null
out="$(docker compose run --rm provisioner 2>&1)"; rc=$?
check "provisioner runs with obsolete user/policy (rc=0)" test "$rc" = "0"
check "removes the obsolete user" test "$(code "${api_url}/users/ghost")" = "404"
check "removes the obsolete policy" test "$(code "${api_url}/policies/dev/ghost-pol")" = "404"
check "log reports both removals" bash -c 'grep -q "user removed: ghost" <<<"$0" && grep -q "policy removed: dev/ghost-pol" <<<"$0"' "$out"
check "provisioner does not remove admin or smoke-app" bash -c '! grep -Eq "user removed: (admin|smoke-app)" <<<"$0"' "$out"

api -X DELETE "${api_url}/users/smoke-app" >/dev/null
docker compose run --rm provisioner >/dev/null 2>&1; rc=$?
check "template user missing: provisioner fails validation" test "$rc" != "0"
docker compose restart rabbitmq >/dev/null 2>&1; wait_api
check "restart without changing the file does NOT restore the user (skip_if_unchanged)" bash -c '! docker compose exec -T rabbitmq rabbitmqctl -q list_users | cut -f1 | grep -qx smoke-app'
# Re-render muda o sal e, portanto, o arquivo: o import (aditivo) no restart recria o usuário.
./scripts/render-definitions.sh >/dev/null; docker compose restart rabbitmq >/dev/null 2>&1; wait_api
check "re-render + restart restores smoke-app via import" bash -c 'docker compose exec -T rabbitmq rabbitmqctl -q list_users | cut -f1 | grep -qx smoke-app'
check "guest does not reappear after restart" test "$(code "${api_url}/users/guest")" = "404"
check "provisioner passes again after the restart" docker compose run --rm provisioner

timeout 45 docker compose run --rm -e RABBITMQ_ADMIN_PASSWORD=wrong-password provisioner >/dev/null 2>&1; rc=$?
check "wrong admin password: provisioner fails fast (< 45 s)" bash -c '[[ "$0" != 124 && "$0" != 0 ]]' "$rc"
docker ps -a --format '{{.Names}}' | grep 'provisioner-run' | xargs -r docker rm -f >/dev/null 2>&1

# ---------------------------------------------------------------- (k) cliente AMQP (T05): falha e limpeza
echo "== (k) AMQP client =="
out="$(docker compose --profile smoke run --rm -e SMOKE_APP_PASSWORD=wrong-password smoke main 2>&1)"; rc=$?
check "wrong smoke-app password: AMQP phase fails (rc!=0 and FAIL line)" bash -c '[[ "$0" != 0 ]] && grep -q "^FAIL  " <<<"$1"' "$rc" "$out"
check "unknown phase name exits non-zero" bash -c '! docker compose --profile smoke run --rm smoke bogus >/dev/null 2>&1'
docker compose --profile smoke run --rm smoke cleanup >/dev/null 2>&1
check "no temporary smoke queues remain" test -z "$(api "${api_url}/queues/dev" | grep -o '"name":"smoke-consumer\.t[^"]*"')"
check "fixed smoke queues are quorum and drained" bash -c \
  'for q in smoke-consumer.ping smoke-consumer.ping.dlq; do curl_out="$(printf "user = \"admin:%s\"\n" "$0" | curl -s -K - "$1/queues/dev/$q")"; grep -q "\"type\":\"quorum\"" <<<"$curl_out" && grep -q "\"messages\":0" <<<"$curl_out" || exit 1; done' "$admin_password" "$api_url"

# ---------------------------------------------------------------- (o) métricas e logs (T06 a T08)
echo "== (o) metrics and logs =="
check "observability-network.sh is idempotent" bash -c './scripts/observability-network.sh && ./scripts/observability-network.sh'
# Recria o coletor apontando para um destino que não resolve (nome .invalid): ele precisa subir, ficar de pé e reter.
unreachable_destination() {
  GELF_HOST=graylog-unreachable.invalid docker compose up -d --force-recreate --no-deps log-shipper >/dev/null 2>&1 || return 1
  sleep 8
  [[ "$(docker compose ps log-shipper --format "{{.State}}")" == "running" ]] && ./scripts/shipper-api.sh /api/v1/uptime | grep -q uptime_sec || return 1
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(docker compose ps -q log-shipper)" | grep -qx 'GELF_HOST=graylog-unreachable.invalid'
}
check "log-shipper starts and stays up with the destination unreachable (GELF_HOST does not resolve)" unreachable_destination
# Restaura o destino real (coletor recriado com o GELF_HOST do .env/padrão).
docker compose up -d --force-recreate --no-deps log-shipper >/dev/null 2>&1; sleep 5
check "log-shipper is back to the real destination and running" bash -c 'docker compose ps log-shipper --format "{{.State}}" | grep -q running && docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$(docker compose ps -q log-shipper)" | grep -qx "GELF_HOST=$0"' "${GELF_HOST:-graylog}"
check "collector config: tcp GELF, unlimited retry, disk buffer, persistent offsets" bash -c \
  'c=./config/fluent-bit/fluent-bit.conf; grep -qE "^ +Mode +tcp" $c && grep -qE "^ +Retry_Limit +no_limits" $c && grep -qE "^ +storage.type +filesystem" $c && grep -qE "^ +DB +/fluent-bit/storage/" $c && grep -qE "^ +storage.total_limit_size" $c'
check "collector keeps only time, level and msg (+ service_name and tag)" bash -c \
  'c=./config/fluent-bit/fluent-bit.conf; for k in time level msg; do grep -qE "^ +Allowlist_key +$k\$" $c || exit 1; done; grep -qE "Add +service_name rabbitmq" $c && grep -qE "Add +tag rabbitmq" $c'
check "collector is hardened (no published ports, read-only fs, cap_drop ALL, mem_limit)" bash -c \
  'id="$(docker compose ps -q log-shipper)"; [[ "$(docker inspect -f "{{len .HostConfig.PortBindings}}" "$id")" == "0" ]] && [[ "$(docker inspect -f "{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Memory}}" "$id")" == "true 134217728" ]] && docker inspect -f "{{.HostConfig.CapDrop}}" "$id" | grep -q ALL'
check "collector API answers (uptime and storage)" bash -c './scripts/shipper-api.sh /api/v1/uptime && ./scripts/shipper-api.sh /api/v1/storage'
check "metrics port rejects a non-GET method" test "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:15692/metrics)" != "200"
# Regressão: o bind mount de arquivo único pode deixar o contêiner com a config antiga (retry de ~2000 s) após editar o
# arquivo; o processo em execução precisa estar com a mesma config do repositório e com o teto de retry de 30 s.
# A imagem é distroless (sem cat): os arquivos são lidos do container por "docker cp" (tar em stdout).
check "running collector has the same config as the repository (no stale bind mount)" bash -c \
  'id="$(docker compose ps -q log-shipper)"; for f in fluent-bit.conf level.lua parsers.conf; do diff <(docker cp "$id:/fluent-bit/etc/$f" - | tar -xO | tr -d "\r") <(tr -d "\r" < "./config/fluent-bit/$f") || exit 1; done'
check "collector retry backoff is capped (no 'retry in' above 40 s in the container logs)" bash -c \
  '[[ "$(docker compose logs log-shipper 2>&1 | grep -o "retry in [0-9]* seconds" | awk "{print \$3}" | sort -n | tail -1)" -le 40 ]]'
check "collector exports the dropped-records counter (buffer ceiling is observable)" bash -c \
  './scripts/shipper-api.sh /api/v1/metrics/prometheus | grep -q "^fluentbit_output_dropped_records_total"'

# ---------------------------------------------------------------- (i) resiliência (opt-in)
if [[ "${SMOKE_DISRUPTIVE:-0}" == "1" ]]; then
  echo "== (i) down/up =="
  api -X PUT -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}' "${api_url}/queues/dev/smoke-persist.marker" >/dev/null
  docker compose down >/dev/null 2>&1
  docker compose up -d --wait rabbitmq >/dev/null 2>&1; wait_api
  check "down/up preserves the volume (marker queue exists)" test "$(code "${api_url}/queues/dev/smoke-persist.marker")" = "200"
  check "provisioner passes after down/up" docker compose run --rm provisioner
  check "guest stays absent after down/up" test "$(code "${api_url}/users/guest")" = "404"
  api -X DELETE "${api_url}/queues/dev/smoke-persist.marker" >/dev/null
fi

echo
if [[ "$failures" -eq 0 ]]; then echo "OK: all edge-case tests passed."; else echo "FAILED: ${failures} test(s)."; exit 1; fi
