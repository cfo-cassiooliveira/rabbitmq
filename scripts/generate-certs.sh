#!/usr/bin/env bash
# Gera a CA local e o certificado do servidor para o complemento TLS (AMQPS 5671) em certs/ (gitignored; nada é versionado).
# A CA é descartável e só vale para desenvolvimento: clientes que a confiam passam a confiar em QUALQUER certificado
# emitido por ela, então a chave da CA (ca.key) fica apenas aqui, em 0600, e nunca é montada em container.
# Não sobrescreve certificados existentes (apague certs/ para renovar). Nenhuma senha/segredo é impresso.
# Em Linux (runner do CI, WSL) o bind mount preserva dono e modo: uma server.key 0600 do usuário do host não seria legível
# pelo usuário "rabbitmq" (uid 999) do container. Em vez de afrouxar o modo, a chave continua 0600 e passa a pertencer a
# esse usuário, via container descartável da própria imagem do broker (só CAP_CHOWN, sem rede). No Git Bash (NTFS, sem
# modo POSIX) o passo não se aplica.
# Uso: ./scripts/generate-certs.sh
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
dir=certs
days=825

# Entrega a server.key (0600) ao usuário rabbitmq da imagem fixada no compose; o nome é resolvido pelo /etc/passwd da imagem.
own_server_key_for_broker() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  local image
  image="$(grep -m1 -oE 'rabbitmq:[^[:space:]"]+@sha256:[0-9a-f]{64}' docker-compose.yml)"
  docker run --rm --network none --user 0 --cap-drop ALL --cap-add CHOWN --security-opt no-new-privileges:true \
    --entrypoint chown -v "$PWD/$dir/server.key:/certs/server.key" "$image" rabbitmq:rabbitmq /certs/server.key
}

if [[ -f "$dir/server.pem" && -f "$dir/ca.pem" ]]; then
  own_server_key_for_broker
  echo "certs/ already has a CA and a server certificate; nothing changed. Delete certs/ to renew."
  exit 0
fi

umask 077
mkdir -p "$dir"
# MSYS_NO_PATHCONV evita que o Git Bash converta "/CN=..." em caminho do Windows.
export MSYS_NO_PATHCONV=1

# CA local (EC P-256; basicConstraints CA, só assina certificados).
openssl ecparam -name prime256v1 -genkey -noout -out "$dir/ca.key"
openssl req -x509 -new -key "$dir/ca.key" -sha256 -days "$days" -subj "/CN=rabbitmq-local-dev-ca" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$dir/ca.pem"

# Servidor: SAN localhost, rabbitmq (nome na rede workspace-messaging) e 127.0.0.1; uso só de servidor TLS.
openssl ecparam -name prime256v1 -genkey -noout -out "$dir/server.key"
openssl req -new -key "$dir/server.key" -subj "/CN=rabbitmq" -out "$dir/server.csr"
printf '%s\n' \
  "basicConstraints=critical,CA:FALSE" \
  "keyUsage=critical,digitalSignature" \
  "extendedKeyUsage=serverAuth" \
  "subjectAltName=DNS:localhost,DNS:rabbitmq,IP:127.0.0.1" > "$dir/server.ext"
openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -sha256 -days "$days" \
  -extfile "$dir/server.ext" -out "$dir/server.pem"
rm -f "$dir/server.csr" "$dir/server.ext" "$dir/ca.srl"

chmod 0600 "$dir/ca.key" "$dir/server.key"
chmod 0644 "$dir/ca.pem" "$dir/server.pem"
openssl verify -CAfile "$dir/ca.pem" "$dir/server.pem"
own_server_key_for_broker
echo "certs/ created: ca.pem (trust this in the clients), server.pem, server.key (0600, owned by the broker user on Linux), ca.key (0600, never mounted)."
