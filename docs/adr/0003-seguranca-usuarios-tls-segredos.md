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

- **Serviço `rabbitmq` sem `cap_drop`/`no-new-privileges`**: diferente de smoke, coletor e `gelf-sink` (que têm `cap_drop: [ALL]`, `no-new-privileges`, `read_only`), o broker roda sem esse endurecimento no compose. Justificativa: a imagem oficial inicia como root e rebaixa para o usuário `rabbitmq` no entrypoint (ajuste de dono dos volumes), o que depende de capabilities; remover tudo não foi validado contra a imagem fixada. Risco aceito em dev (portas só em 127.0.0.1, rede interna sem saída, memória limitada); testar `cap_drop` seletivo é item do ADR de produção.
- **Sem TLS no management e no AMQP padrão em dev**: tráfego só em loopback/rede Docker.
