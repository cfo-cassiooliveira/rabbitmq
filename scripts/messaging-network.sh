#!/usr/bin/env bash
# Confere se a rede compartilhada "workspace-messaging" existe. Quem a cria é o compose deste projeto
# (docker compose up -d); os demais projetos a usam com "external: true".
set -euo pipefail

if docker network inspect workspace-messaging >/dev/null 2>&1; then
  echo "workspace-messaging: ok"
else
  echo "workspace-messaging does not exist: start the broker (docker compose up -d) to create it." >&2
  exit 1
fi
