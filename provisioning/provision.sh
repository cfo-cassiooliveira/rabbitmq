#!/usr/bin/env bash
# Provisionamento idempotente do broker pela API de management: o import de definitions é aditivo, então aqui
# se garante o que ele não faz (remover o guest e usuários/policies obsoletos) e se valida o resultado.
# Escopo: só o que o template gerencia (vhosts do definitions.json e seus usuários/policies); o resto é preservado.
# Pode rodar a cada "docker compose up"/"run": a segunda execução não altera nada.
# Também aplica as operator_policies, que o import ignora. A validação ao final cobre usuários, guest, quantidade de
# policies, operator policies e tipo das filas; não compara permissões nem o conteúdo das policies.
set -euo pipefail

: "${RABBITMQ_API_URL:?RABBITMQ_API_URL is required}"
: "${RABBITMQ_ADMIN_USER:?RABBITMQ_ADMIN_USER is required}"
: "${RABBITMQ_ADMIN_PASSWORD:?RABBITMQ_ADMIN_PASSWORD is required}"
DEFINITIONS_FILE="${DEFINITIONS_FILE:-/provisioning/definitions.json}"

log() { echo "[provision] $*" >&2; }

# Codifica um segmento de URL (nome de usuário, policy, fila, vhost).
uri() { jq -rn --arg v "$1" '$v|@uri'; }

# Credencial via configuração do curl em stdin (nunca na linha de comando); escapa \ e " do valor.
curl_auth() {
  local credential="${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}"
  credential="${credential//\\/\\\\}"
  credential="${credential//\"/\\\"}"
  printf 'user = "%s"\n' "$credential"
}

# Uso: api <method> <path> -> body on stdout; fails (body on stderr) if HTTP >= 400.
api() {
  local method="$1" path="$2" response
  if ! response="$(curl_auth | curl -sS --fail-with-body -K - -H "Accept: application/json" -X "$method" "${RABBITMQ_API_URL}/api${path}")"; then
    echo "[provision] ${method} ${path} failed: ${response}" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

# Código HTTP de um GET (sem falhar em 404).
http_code() {
  curl_auth | curl -sS -o /dev/null -w '%{http_code}' -K - "${RABBITMQ_API_URL}/api$1"
}

# Espera a API; credencial recusada (401/403) falha na hora em vez de esperar o timeout.
wait_for_api() {
  local code
  for _ in $(seq 1 60); do
    code="$(http_code /overview 2>/dev/null || true)"
    case "$code" in
      200) return 0 ;;
      401 | 403)
        echo "management API rejected the admin credentials (HTTP ${code}); check RABBITMQ_ADMIN_PASSWORD" >&2
        exit 1
        ;;
    esac
    sleep 5
  done
  echo "RabbitMQ management API did not become available" >&2
  exit 1
}

# Remove usuários que não estão nas definitions, a menos que tenham permissão em vhost fora do template
# (usuários de apps em outros vhosts não são do escopo deste projeto).
prune_users() {
  local expected managed_vhosts name outside
  expected="$(jq -r '.users[].name' "$DEFINITIONS_FILE")"
  managed_vhosts="$(jq -r '.vhosts[].name' "$DEFINITIONS_FILE")"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" <<<"$expected" && continue
    outside="$(api GET "/users/$(uri "$name")/permissions" | jq -r '.[].vhost' | grep -vxF "$managed_vhosts" || true)"
    if [[ -n "$outside" ]]; then
      log "user kept (has permissions outside the managed vhosts): ${name}"
      continue
    fi
    api DELETE "/users/$(uri "$name")" >/dev/null
    log "user removed: ${name}"
  done < <(api GET /users | jq -r '.[].name')
}

# Remove policies que não estão nas definitions, só nos vhosts gerenciados pelo template.
prune_policies() {
  local expected managed_vhosts name vhost
  expected="$(jq -r '.policies[] | "\(.vhost)/\(.name)"' "$DEFINITIONS_FILE")"
  managed_vhosts="$(jq -r '.vhosts[].name' "$DEFINITIONS_FILE")"
  while IFS=$'\t' read -r vhost name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$vhost" <<<"$managed_vhosts" || continue
    if ! grep -qxF "${vhost}/${name}" <<<"$expected"; then
      api DELETE "/policies/$(uri "$vhost")/$(uri "$name")" >/dev/null
      log "policy removed: ${vhost}/${name}"
    fi
  done < <(api GET /policies | jq -r '.[] | [.vhost, .name] | @tsv')
}

# O import de definitions ignora "operator_policies": o provisionador as aplica pela API (PUT é idempotente) e remove
# as obsoletas dos vhosts do template. Operator policy mescla com a policy da fila; usada para o delivery-limit.
sync_operator_policies() {
  local vhost name body expected managed_vhosts
  while IFS= read -r body; do
    [[ -z "$body" ]] && continue
    vhost="$(jq -r '.vhost' <<<"$body")"; name="$(jq -r '.name' <<<"$body")"
    curl_auth | curl -sS --fail-with-body -K - -H "content-type: application/json" -X PUT \
      --data-binary "$(jq -c '{pattern, definition, priority, "apply-to": .["apply-to"]}' <<<"$body")" \
      "${RABBITMQ_API_URL}/api/operator-policies/$(uri "$vhost")/$(uri "$name")" >/dev/null ||
    { echo "[provision] operator policy ${vhost}/${name} failed" >&2; return 1; }
  done < <(jq -c '(.operator_policies // [])[]' "$DEFINITIONS_FILE")
  expected="$(jq -r '(.operator_policies // [])[] | "\(.vhost)/\(.name)"' "$DEFINITIONS_FILE")"
  managed_vhosts="$(jq -r '.vhosts[].name' "$DEFINITIONS_FILE")"
  while IFS=$'\t' read -r vhost name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$vhost" <<<"$managed_vhosts" || continue
    if ! grep -qxF "${vhost}/${name}" <<<"$expected"; then
      api DELETE "/operator-policies/$(uri "$vhost")/$(uri "$name")" >/dev/null
      log "operator policy removed: ${vhost}/${name}"
    fi
  done < <(api GET /operator-policies | jq -r '.[] | [.vhost, .name] | @tsv')
}

# Falha se o broker divergir do esperado nas definitions (usuários, policies, guest e tipo das filas).
validate() {
  local expected actual user vhost name type
  # Todo usuário do template deve existir (usuários de outros vhosts são permitidos).
  while IFS= read -r user; do
    [[ "$(http_code "/users/$(uri "$user")")" == "200" ]] || { echo "user missing: ${user}" >&2; exit 1; }
  done < <(jq -r '.users[].name' "$DEFINITIONS_FILE")

  # Só as policies dos vhosts do template são comparadas.
  expected="$(jq '.policies | length' "$DEFINITIONS_FILE")"
  actual="$(api GET /policies | jq --slurpfile d "$DEFINITIONS_FILE" \
    '[.[] | select(.vhost as $v | $d[0].vhosts | map(.name) | index($v))] | length')"
  [[ "$expected" == "$actual" ]] || { echo "policies: expected ${expected}, found ${actual}" >&2; exit 1; }

  [[ "$(http_code /users/guest)" == "404" ]] || { echo "guest still exists" >&2; exit 1; }

  # Operator policies do template (o import é aditivo): devem existir no broker.
  while IFS=$'\t' read -r vhost name; do
    [[ "$(http_code "/operator-policies/$(uri "$vhost")/$(uri "$name")")" == "200" ]] || { echo "operator policy missing: ${vhost}/${name}" >&2; exit 1; }
  done < <(jq -r '(.operator_policies // [])[] | [.vhost, .name] | @tsv' "$DEFINITIONS_FILE")

  # Filas de definitions existem no vhost e são quorum.
  while IFS=$'\t' read -r vhost name; do
    type="$(api GET "/queues/$(uri "$vhost")/$(uri "$name")" | jq -r '.type')"
    [[ "$type" == "quorum" ]] || { echo "queue ${vhost}/${name}: expected quorum, found ${type}" >&2; exit 1; }
  done < <(jq -r '.queues[] | [.vhost, .name] | @tsv' "$DEFINITIONS_FILE")
}

# Resumo normalizado e ordenado do estado (sem dados voláteis); duas execuções seguidas devem dar o mesmo valor.
# A idempotência é verificada pelo estado, não só pelo código de saída: o smoke compara o resumo de duas execuções.
state_digest() {
  {
    api GET /users | jq -c 'map({name, tags}) | sort_by(.name)'
    api GET /permissions | jq -c 'map({user, vhost, configure, write, read}) | sort_by(.user, .vhost)'
    api GET /policies | jq -c 'map({vhost, name, pattern, definition}) | sort_by(.vhost, .name)'
    api GET /queues | jq -c 'map({vhost, name, type}) | sort_by(.vhost, .name)'
  } | sha256sum | cut -d' ' -f1
}

main() {
  wait_for_api
  if [[ "$(http_code /users/guest)" == "200" ]]; then
    api DELETE /users/guest >/dev/null
    log "user removed: guest"
  fi
  prune_users
  prune_policies
  sync_operator_policies
  validate
  log "state-digest=$(state_digest)"
  log "ok"
}

# Permite carregar as funções com "source" (testes) sem executar o provisionamento.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main; fi
