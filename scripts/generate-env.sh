#!/usr/bin/env bash
# Gera o .env local com segredos aleatórios (nunca versionado) e renderiza as definitions.
# Não sobrescreve um .env existente (mas renderiza as definitions se faltarem). Os segredos nunca são impressos.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
if [[ -f .env ]]; then
  echo ".env already exists; nothing changed. Delete it to generate new secrets."
  # O bind mount do compose exige o definitions.json: gera quando faltar (ex.: clone novo com .env copiado).
  [[ -f definitions/definitions.json ]] || ./scripts/render-definitions.sh
  exit 0
fi

random() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

umask 077
cat > .env <<ENVEOF
# Gerado por scripts/generate-env.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ). NUNCA versione este arquivo.
RABBITMQ_ADMIN_PASSWORD=$(random 24)
RABBITMQ_SMOKE_APP_PASSWORD=$(random 24)
ENVEOF

echo ".env created (mode 0600). UI user: admin; password in RABBITMQ_ADMIN_PASSWORD in the .env."
./scripts/render-definitions.sh
