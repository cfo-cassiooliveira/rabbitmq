# ADR-0003: Segurança — usuários, permissões mínimas, TLS e segredos

- **Status**: Aceito
- **Data**: 2026-11-19
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. IV.1 a IV.7, Art. VII

## Contexto

O steering exige `guest` removido, usuário por aplicação com permissões mínimas e TLS fora de dev. O broker é local, mas é o
padrão que as apps herdarão.

## Decisão

1. **`guest` removido**: fora das definitions; o provisionador o apaga se existir; `loopback_users` fica no padrão (defesa em profundidade); o smoke prova que `guest/guest` é recusado por AMQP e HTTP.
2. Usuários: `admin` (tag `administrator`, só UI/API, senha aleatória no `.env`), `smoke-app` (só teste) e, na fase seguinte, um por app (`<app>`), sem tags de management.
3. **Permissões mínimas por prefixo**: `configure/write/read` com regex `^<app>\.` (nomes de exchange e fila). O smoke prova que declarar/publicar fora do prefixo é recusado.
   O `smoke-app` tem prefixo duplo `^smoke(-consumer)?\.` (exchange `smoke.` e fila `smoke-consumer.`), pois o prefixo único `^smoke\.` não cobriria a fila de smoke.
4. **Segredos** só no `.env` (modo 0600, gerado com `openssl rand`, não versionado) e em `definitions.json` gerado como **hash**; gitleaks e trivy no CI. Segredos das apps ficam no cofre/`.env` de cada app.
5. Portas só em `127.0.0.1`; EPMD/distribuição não publicados; Prometheus sem autenticação mas só em loopback/rede interna (`prometheus.authentication.enabled` é opção para fora de dev).
6. **TLS**: dev em texto plano no loopback; **TLS opcional só no servidor** (listener AMQPS 5671 via complemento `docker-compose.tls.yml` + `config/tls.conf`; CA local em `certs/`, gitignored; TLS 1.3/1.2, cifras padrão do OTP sem as fracas, ECDSA P-256, `ca.key` nunca montada). `ssl_options.verify = verify_peer` com `fail_if_no_peer_cert = false`: o certificado de cliente é verificado se enviado, mas não exigido; **mTLS está fora do escopo** (autenticação por usuário e senha, o cliente valida o servidor contra a CA; o smoke-tls prova isso). O management (15672) segue **sem TLS em dev** (só em 127.0.0.1). TLS obrigatório (e avaliação de mTLS) fica para o ADR de produção.
7. Management UI com usuário local; OAuth2/Keycloak fica para a fase seguinte (sem tocar no Keycloak agora).

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Manter `guest` só em loopback | Padrão da imagem | Credencial conhecida; viola o steering | Rejeitada |
| TLS obrigatório já em dev | Paridade com prod | Atrito (CA, confiança nos clientes) | Opcional por profile |
| OAuth2 na UI agora | SSO | Altera o Keycloak (fora de escopo) | Adiada |

## Consequências

- **Positivas**: segurança por padrão verificada por teste.
- **Negativas / riscos**: sem TLS em dev; `admin` compartilhado na UI.
- **Ações decorrentes**: T04, T05, T09.

## Riscos aceitos

- **Serviço `rabbitmq` sem `cap_drop`** (o `no-new-privileges` deixou de ser risco, ver "Atualização" abaixo): diferente de smoke, coletor e `gelf-sink` (que têm `cap_drop: [ALL]` e `read_only`), o broker mantém as capabilities padrão do Docker. Evidência (2026-11-23, imagem fixada, containers descartáveis com `no-new-privileges`): com `cap_drop: [ALL]` o entrypoint falha em `chown: changing ownership of '/var/lib/rabbitmq/.wget-hsts': Operation not permitted` (a imagem traz esse arquivo do root, e o entrypoint ajusta o dono antes do `gosu`); com `ALL` + `SETUID`/`SETGID` falha igual; com `ALL` + `CHOWN`/`SETUID`/`SETGID` o broker sobe (`beam.smp` uid 999, `CapEff=0`), mas o `rabbitmq-diagnostics` executado como root (healthcheck e `docker compose exec` dos smokes) perde o acesso ao `.erlang.cookie` (`eacces`), o que exigiria `DAC_OVERRIDE` (amplo) ou rodar healthcheck e smokes como `rabbitmq`. Como o processo do broker já roda sem capabilities efetivas, o ganho é pequeno diante dessa mudança: risco aceito em dev (portas só em 127.0.0.1, rede interna sem saída, memória limitada); `cap_drop` seletivo (`CHOWN`, `SETUID`, `SETGID` + healthcheck como `rabbitmq`) fica para o ADR de produção.
- **Sem TLS no management e no AMQP padrão em dev**: tráfego só em loopback/rede Docker.

## Atualização (DEV-003, 2026-11-23)

1. **`no-new-privileges` no broker**: `security_opt: ["no-new-privileges:true"]` no serviço `rabbitmq` (herdado pelo complemento TLS, que só acrescenta portas e volumes). O entrypoint continua iniciando como root e rebaixando com `gosu`, que chama `setuid`/`setgid` diretamente e não depende de bit setuid; por isso a trava não afeta o rebaixamento. O smoke (seção a) prova `SecurityOpt` com `no-new-privileges:true` e, no processo do broker (PID 1 do container, o `beam.smp` que o entrypoint alcança por `exec`), `NoNewPrivs: 1` e uid 999. A prova olha só o PID 1 porque as CLIs (`rabbitmq-diagnostics` do healthcheck e `docker compose exec` dos smokes) sobem VMs Erlang próprias, também chamadas `beam.smp` e como root; varrer todos os `beam.smp` tornava o check intermitente.
2. **TLS no CI**: o bind mount preserva dono e modo, e no runner Linux a `server.key` 0600 do usuário do host não era legível pelo uid 999 do container (o broker falha com `ssl_options.keyfile invalid ... cannot be read`, reproduzido). O `scripts/generate-certs.sh` mantém a chave em **0600** e, fora do Git Bash/NTFS, entrega o arquivo ao usuário `rabbitmq` da própria imagem fixada num container descartável (`--network none`, `--cap-drop ALL --cap-add CHOWN`, `no-new-privileges`). O `ca.key` segue 0600 do usuário do host e nunca é montado. A variável `KEY_MODE` (que permitia 0644) foi removida. O job `smoke-tls` do CI roda `scripts/smoke-tls.sh`, que confere modo e dono das chaves em Linux.
