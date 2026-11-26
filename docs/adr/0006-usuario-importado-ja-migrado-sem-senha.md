# ADR-0006: Usuário importado nasce migrado no Keycloak, sem senha e sem consultar o legado

- **Status**: Aceito
- **Data**: 2026-11-25 (recriado a partir do plano de 24/11 no Notion)
- **Decisores**: responsável técnico
- **Artigos da Constituição relacionados**: Art. IV.2, IV.4, IV.6, Art. VII.2, Art. III.4

## Contexto

Cada pessoa da planilha precisa de acesso. O Cadastro já migra usuários do Legado sob demanda no primeiro login. Para a importação, a planilha é a fonte; consultar o legado por pessoa acoplaria o fluxo e a sua disponibilidade.

## Decisão

1. O consumidor cria o usuário **direto no Keycloak** pela Admin API, com o client `cadastro-importer` (menor privilégio, service account separada da de leitura), **sem consultar o legado**.
2. **Sem senha**: usuário criado com a ação obrigatória `UPDATE_PASSWORD` e e-mail de ativação (`execute-actions-email`, 72 h; Mailpit em dev). Nenhuma senha em texto claro, em log ou na caixa de entrada.
3. O atributo `importLineId` impede duplicar; pessoa já existente no Keycloak é pulada (linha "já existente").
4. Depois de criar, o consumidor **marca o Legado** como migrado pela API interna existente (consulta + `PUT users/{id}/migration`) apenas quando há **um único candidato com e-mail exatamente igual**. Login inexistente não é erro; ambiguidade vira aviso. Falha na marcação **não desfaz** o usuário do Keycloak e fica em `LegacyMarkStatus`.
5. O usuário importado **não é copiado** para o Legado.
6. Arquitetura-alvo (ADR-0008, depois do MVP): evento `identity.user.migrated.v1` consumido pelo Legado, no lugar da chamada síncrona.

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Senha temporária gerada | Acesso imediato | Segredo em trânsito/e-mail/log; viola Art. IV | Risco de segurança |
| Importar via migração sob demanda do Legado | Reaproveita o fluxo | Exige consultar o legado por pessoa; pessoas fora do legado não entram | Acoplamento e cobertura |
| Copiar o usuário para o Legado | Legado completo | Duplica dado pessoal e responsabilidade | Fora do objetivo |
| Marcar o Legado por evento já no MVP | Desacoplado | Mais uma peça no MVP | Adiado para ADR-0008 |

## Consequências

- **Positivas**: nenhum segredo trafega; fluxo independente da disponibilidade do Legado; idempotência por atributo.
- **Negativas / riscos**: quem existir no Legado e na planilha pode ficar com contas separadas (sem candidato único); marcação pode ficar pendente; dependência da disponibilidade do SMTP para ativação.
- **Ações decorrentes**: K0 (client, role, atributo, SMTP), C5a/C5c, L2 (chave do Cadastro restrita), teste de 0/1/vários candidatos.
