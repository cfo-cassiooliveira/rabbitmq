#!/usr/bin/env bash
# Gera o .env local com segredos aleatórios (nunca versionado) e renderiza as definitions.
# Não sobrescreve um .env existente (mas renderiza as definitions se faltarem). Os segredos nunca são impressos.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
if [[ -f .env ]]; then
  # .env de versões anteriores: acrescenta só a senha que faltar, sem tocar nas existentes.
  if ! grep -q '^RABBITMQ_CADASTRO_APP_PASSWORD=.' .env; then
    # Garante quebra de linha antes: um .env sem newline final colaria a variável na linha anterior.
    [[ -s .env && -n "$(tail -c1 .env)" ]] && printf '\n' >> .env
    printf 'RABBITMQ_CADASTRO_APP_PASSWORD=%s\n' "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)" >> .env
    echo "RABBITMQ_CADASTRO_APP_PASSWORD added to the existing .env."
    ./scripts/render-definitions.sh
  fi
  echo ".env already exists; existing secrets unchanged. Delete it to generate new secrets."
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
RABBITMQ_CADASTRO_APP_PASSWORD=$(random 24)
ENVEOF

echo ".env created (mode 0600). UI user: admin; password in RABBITMQ_ADMIN_PASSWORD in the .env."
./scripts/render-definitions.sh
