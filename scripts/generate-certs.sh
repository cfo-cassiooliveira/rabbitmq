#!/usr/bin/env bash
# Gera a CA local e o certificado do servidor para o profile TLS (AMQPS 5671) em certs/ (gitignored; nada é versionado).
# A CA é descartável e só vale para desenvolvimento: clientes que a confiam passam a confiar em QUALQUER certificado
# emitido por ela, então a chave da CA (ca.key) fica apenas aqui, em 0600, e nunca é montada em container.
# Não sobrescreve certificados existentes (apague certs/ para renovar). Nenhuma senha/segredo é impresso.
# Variável opcional: KEY_MODE (padrão 0600). Em runner Linux, onde o bind mount preserva dono e modo, o usuário "rabbitmq"
# do container não lê uma chave 0600 do host; use KEY_MODE=0644 só em ambiente descartável.
# Uso: ./scripts/generate-certs.sh
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
dir=certs
days=825
key_mode="${KEY_MODE:-0600}"

if [[ -f "$dir/server.pem" && -f "$dir/ca.pem" ]]; then
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

chmod 0600 "$dir/ca.key"
chmod "$key_mode" "$dir/server.key"
chmod 0644 "$dir/ca.pem" "$dir/server.pem"
echo "certs/ created: ca.pem (trust this in the clients), server.pem, server.key (mode ${key_mode}), ca.key (0600, never mounted)."
openssl verify -CAfile "$dir/ca.pem" "$dir/server.pem"
