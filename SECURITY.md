# Política de segurança

Projeto de infraestrutura local (RabbitMQ 4.x em Docker) do workspace.

- **Versões suportadas**: a versão da branch `master`.
- **Reporte de vulnerabilidades**: não abra issue pública; use o relato privado de vulnerabilidades do GitHub (aba Security › Report a vulnerability) do repositório.
- **Segredos**: nunca no repositório; o `.env` é gerado por `scripts/generate-env.sh` (modo 0600) e fica fora do git.
  Se um segredo vazar, apague o `.env`, gere outro e recrie o broker (`docker compose down -v` apaga os dados).
- **Superfície**: portas publicadas apenas em `127.0.0.1`; usuário `guest` removido; permissões mínimas por prefixo
  (ver `docs/adr/0003-seguranca-usuarios-tls-segredos.md`).
