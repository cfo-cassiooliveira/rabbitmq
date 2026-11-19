#!/usr/bin/env bash
# Consulta a API HTTP interna do coletor de logs (Fluent Bit, porta 2020) a partir de FORA do container.
# A imagem do coletor é distroless (sem shell nem curl), então a requisição sai de um container descartável que
# compartilha a rede do coletor (--network container:...) e usa o bash da imagem do broker (já presente, sem pull novo).
# Uso: ./scripts/shipper-api.sh /api/v1/uptime                       (coletor real)
#      SHIPPER=log-shipper-test ./scripts/shipper-api.sh /api/v1/storage   (coletor de teste do smoke do fallback)
# Saída: corpo da resposta; código != 0 se o coletor não existe, não responde ou não devolve HTTP 200.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
shipper="${SHIPPER:-log-shipper}"
path="${1:?uso: shipper-api.sh /caminho}"

cid="$(docker compose --profile logs-test ps -q "$shipper" 2>/dev/null)"
[[ -n "$cid" ]] || { echo "${shipper} is not running" >&2; exit 1; }
broker_cid="$(docker compose ps -q rabbitmq 2>/dev/null)"
image="$(docker inspect -f '{{.Image}}' "$broker_cid" 2>/dev/null)"
[[ -n "$image" ]] || { echo "broker image not found (is the broker up?)" >&2; exit 1; }

# Cliente HTTP mínimo em bash puro (/dev/tcp): GET, exige "200" e imprime só o corpo.
# O servidor mantém a conexão aberta e responde em chunks: lê o cabeçalho e o corpo sem esperar o fechamento.
http_get='
exec 3<>/dev/tcp/127.0.0.1/2020 || exit 2
printf "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" "$1" >&3
IFS= read -r -t 5 -u 3 status_line || { echo "no response" >&2; exit 2; }
status="$(cut -d" " -f2 <<<"$status_line")"
while IFS= read -r -t 5 -u 3 header; do
  [[ "${header%$(printf "\r")}" == "" ]] && break
done
[[ "$status" == "200" ]] || { echo "HTTP ${status:-no response}" >&2; exit 22; }
# Corpo em chunked (o Fluent Bit não manda Content-Length): lê "tamanho em hex, dados, CRLF" até o chunk 0.
while IFS= read -r -t 5 -u 3 size_line; do
  size=$((16#$(tr -dc 0-9a-fA-F <<<"$size_line")))
  [[ "$size" -gt 0 ]] || break
  head -c "$size" <&3
  IFS= read -r -t 5 -u 3 _
done
echo
'
# O "timeout" de dentro do container garante o encerramento (matar só o cliente docker deixaria o container preso).
timeout 30 docker run --rm --network "container:${cid}" --user 65534 --cap-drop ALL \
  --security-opt no-new-privileges:true --read-only --entrypoint timeout "$image" 20 bash -c "$http_get" _ "$path" </dev/null
