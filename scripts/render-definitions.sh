#!/usr/bin/env bash
# Gera definitions/definitions.json (gitignored) a partir do template, calculando o password_hash dos
# usuários com as senhas do .env. Formato do hash (RabbitMQ): base64(salt[4 bytes] + SHA-256(salt + senha)).
# Com RENDER_SALT_HEX (8 hex) o sal fica fixo, para testes determinísticos (scripts/smoke-test.sh).
# Por que gerar o arquivo: a topologia fica versionada e revisável por diff sem senha nem hash no git. Custo: um passo a
# mais a cada mudança, e o sal novo altera o arquivo mesmo sem mudança no template (o que faz o broker reimportar).
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
command -v xxd >/dev/null || { echo "xxd is required" >&2; exit 1; }
[[ -f .env ]] || { echo ".env not found: run ./scripts/generate-env.sh" >&2; exit 1; }
if [[ -n "${RENDER_SALT_HEX:-}" && ! "$RENDER_SALT_HEX" =~ ^[0-9a-fA-F]{8}$ ]]; then
  echo "RENDER_SALT_HEX must be exactly 8 hex characters" >&2
  exit 1
fi

# Lê só a chave pedida (sem "source"); remove o CR final e um par de aspas externas, como o docker compose faz.
env_value() {
  local value
  value="$(grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r')"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
  printf '%s' "$value"
}

# Uso: password_hash <senha>
password_hash() {
  local salt_hex="${RENDER_SALT_HEX:-$(openssl rand -hex 4)}"
  {
    printf '%s' "$salt_hex" | xxd -r -p
    { printf '%s' "$salt_hex" | xxd -r -p; printf '%s' "$1"; } | openssl dgst -sha256 -binary
  } | openssl base64 -A
}

admin_password="$(env_value RABBITMQ_ADMIN_PASSWORD)"
smoke_password="$(env_value RABBITMQ_SMOKE_APP_PASSWORD)"
cadastro_password="$(env_value RABBITMQ_CADASTRO_APP_PASSWORD)"
[[ -n "$admin_password" && -n "$smoke_password" && -n "$cadastro_password" ]] || { echo "passwords missing in .env" >&2; exit 1; }

output="definitions/definitions.json"
# Os hashes são base64 ([A-Za-z0-9+/=]), seguros como substituição no sed com delimitador "|".
sed -e "s|__ADMIN_PASSWORD_HASH__|$(password_hash "$admin_password")|" \
    -e "s|__SMOKE_APP_PASSWORD_HASH__|$(password_hash "$smoke_password")|" \
    -e "s|__CADASTRO_APP_PASSWORD_HASH__|$(password_hash "$cadastro_password")|" \
    definitions/definitions.template.json > "${output}.tmp"

if grep -q '__[A-Z_]*__' "${output}.tmp"; then
  rm -f "${output}.tmp"
  echo "unreplaced placeholder in the template" >&2
  exit 1
fi
# 0644: o usuário do container (rabbitmq) precisa ler o bind mount; o arquivo só tem hashes e é gitignored.
chmod 644 "${output}.tmp"
mv "${output}.tmp" "$output"
echo "definitions/definitions.json generated."
