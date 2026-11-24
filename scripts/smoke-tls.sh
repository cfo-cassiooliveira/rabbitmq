#!/usr/bin/env bash
# Smoke do profile TLS (AMQPS 5671): gera os certificados (se faltarem), sobe o broker com o complemento TLS, roda o
# cliente pika verificando a CA e confere que o texto plano e a UI de management (sem TLS em dev) continuam funcionando.
# Ao final o broker volta ao perfil padrão (sem TLS), a menos que KEEP_TLS=1. Requer o .env e o broker já criado.
# Roda também no CI (job "smoke TLS" do .github/workflows/ci.yml), num runner Linux com usuário não-root.
# Uso: ./scripts/smoke-tls.sh      (não rode junto com outro smoke: ele recria o broker)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
tls() { docker compose -f docker-compose.yml -f docker-compose.tls.yml --profile tls "$@"; }

env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }
admin_password="$(env_value RABBITMQ_ADMIN_PASSWORD)"
wait_healthy() {
  for _ in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q rabbitmq)" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 3
  done
  return 1
}
restore_plain() {
  [[ "${KEEP_TLS:-0}" == "1" ]] && return 0
  timeout 200 docker compose up -d --force-recreate --no-deps rabbitmq >/dev/null 2>&1
  wait_healthy
}
trap restore_plain EXIT

echo "== (t) TLS (AMQPS) =="
./scripts/generate-certs.sh >/dev/null || { echo "could not generate the certificates"; exit 1; }
check "certs: ca.key is never mounted into the container" bash -c '! grep -q "ca.key" docker-compose.tls.yml'
# NTFS (Git Bash no Windows) não guarda modo POSIX: a permissão 0600 só é verificável em Linux/WSL.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "SKIP  certs: key file modes and owner (NTFS does not keep POSIX modes; checked on Linux/WSL and in CI)" ;;
  *)
    check "certs: ca.key and server.key are not readable by group/others (0600)" bash -c '[[ "$(stat -c %a certs/ca.key)" == "600" ]] && [[ "$(stat -c %a certs/server.key)" == "600" ]]'
    # O bind mount preserva o dono: a chave pertence ao usuário rabbitmq (uid 999) do container, não ao usuário do host.
    check "certs: server.key is owned by the broker user (uid 999), ca.key stays with the host user" bash -c \
      '[[ "$(stat -c %u certs/server.key)" == "999" ]] && [[ "$(stat -c %u certs/ca.key)" == "$(id -u)" ]]'
    ;;
esac
check "certs: server certificate has SAN localhost, rabbitmq and 127.0.0.1" bash -c \
  'out="$(openssl x509 -in certs/server.pem -noout -ext subjectAltName)"; grep -q "DNS:localhost" <<<"$out" && grep -q "DNS:rabbitmq" <<<"$out" && grep -q "IP Address:127.0.0.1" <<<"$out"'
check "certs: git ignores certs/" git check-ignore -q certs/ca.key

if timeout 300 docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate --no-deps rabbitmq >/dev/null 2>&1 && wait_healthy; then
  pass "broker is healthy with the TLS complement"
else
  fail "broker did not become healthy with the TLS complement"
  docker compose logs --tail 40 rabbitmq 2>&1 | grep -iE "tls|ssl|cert|error" | head -10
fi
check "AMQPS port 5671 is published only on 127.0.0.1" bash -c \
  'test "$(docker inspect -f "{{range \$b := index .NetworkSettings.Ports \"5671/tcp\"}}{{\$b.HostIp}} {{end}}" "$(docker compose ps -q rabbitmq)" | xargs)" = "127.0.0.1"'
check "plain AMQP 5672 still listens (default profile unchanged)" bash -c 'docker compose exec -T rabbitmq rabbitmq-diagnostics -q listeners | grep -q "port: 5672"'
check "AMQPS listener is active on 5671" bash -c 'docker compose exec -T rabbitmq rabbitmq-diagnostics -q listeners | grep -q "port: 5671"'
check "management (15672) stays plain HTTP in dev" test "$(printf 'user = "admin:%s"\n' "$admin_password" | curl -s -o /dev/null -w '%{http_code}' -K - http://127.0.0.1:15672/api/overview)" = "200"
check "management does not answer TLS on 15672" bash -c '! curl -sk --max-time 5 https://127.0.0.1:15672/api/overview >/dev/null'

out="$(timeout 240 docker compose -f docker-compose.yml -f docker-compose.tls.yml --profile tls run --rm -T smoke-tls tls 2>&1)"; rc=$?
grep -E '^(PASS|FAIL)  ' <<<"$out"
failures=$((failures + $(grep -c '^FAIL  ' <<<"$out")))
grep -q '^PASS  ' <<<"$out" || fail "AMQPS phase produced no PASS line"
if [[ "$rc" != "0" ]] && ! grep -q '^FAIL  ' <<<"$out"; then fail "AMQPS phase exited with code ${rc}"; fi

echo
if [[ "$failures" -eq 0 ]]; then echo "OK: TLS smoke passed."; else echo "FAILED: ${failures} TLS test(s)."; exit 1; fi
