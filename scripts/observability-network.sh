#!/usr/bin/env bash
# Garante a rede externa "observability" (GELF do Graylog em graylog:12201), que o log-shipper usa com "external: true".
# O compose do graylog declara a mesma rede (nome fixo); se ele subir depois e achar a rede criada aqui, apenas avisa
# sobre o rótulo, sem recriá-la. Idempotente. Uso: ./scripts/observability-network.sh && docker compose up -d --build
set -euo pipefail

if docker network inspect observability >/dev/null 2>&1; then
  echo "observability: ok"
else
  docker network create observability >/dev/null
  echo "observability: created (the Graylog may not be running; the log-shipper will retain logs until it is)"
fi
