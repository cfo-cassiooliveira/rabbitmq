#!/usr/bin/env bash
# Exporta as definitions do broker (vhosts, usuários com hash, permissões, policies, filas, exchanges, bindings)
# pela API de management. O arquivo contém hashes de senha: fica fora do git (backups/, modo 0600).
# Não exporta mensagens nem o conteúdo dos volumes. Restaurar: importar o JSON pela API/UI do management.
# Uso: ./scripts/backup-definitions.sh [diretório-de-saída]   (padrão: backups/)   Requer o .env e o broker no ar.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
out_dir="${1:-backups}"
[[ -f .env ]] || { echo ".env not found: run ./scripts/generate-env.sh" >&2; exit 1; }

admin_password="$(grep -E '^RABBITMQ_ADMIN_PASSWORD=' .env | head -1 | cut -d= -f2- | tr -d '\r')"
[[ -n "$admin_password" ]] || { echo "RABBITMQ_ADMIN_PASSWORD missing in .env" >&2; exit 1; }

umask 077
mkdir -p "$out_dir"
target="$out_dir/definitions-$(date -u +%Y%m%dT%H%M%SZ).json"

# O segredo vai por arquivo de config do curl (stdin), nunca pela linha de comando.
status="$(printf 'user = "admin:%s"\n' "$admin_password" |
  curl -s -K - -o "$target" -w '%{http_code}' http://127.0.0.1:15672/api/definitions)"
if [[ "$status" != "200" ]]; then
  rm -f "$target"
  echo "export failed (HTTP $status)" >&2
  exit 1
fi
chmod 600 "$target"
echo "definitions exported to $target"
