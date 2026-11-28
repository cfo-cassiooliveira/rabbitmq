# Imagem mínima para o provisionamento via API de management (curl + jq). Alpine 3.22 fixado por digest.
# Falar com a API, e não usar rabbitmqctl, dispensa compartilhar o cookie Erlang do broker com outro container.
# Custo: os pacotes do apk não têm versão fixada, só a imagem base.
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
RUN apk add --no-cache curl jq bash
WORKDIR /provisioning
COPY --chmod=755 provision.sh ./
USER nobody
ENTRYPOINT ["/provisioning/provision.sh"]
