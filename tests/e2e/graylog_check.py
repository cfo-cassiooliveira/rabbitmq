"""Verificações do e2e real broker -> Fluent Bit -> Graylog (scripts/e2e-graylog.sh).

Roda no container descartável da imagem do smoke, sem rede (--network none): recebe pelo stdin a resposta JSON da
API do Graylog (obtida pelo script no host) e imprime o resultado. Nada sensível chega aqui (só textos de log).
Subcomandos:
  count                         quantas mensagens únicas (time + texto) a busca devolveu
  alert-search <título> <run>   corpo da busca que reproduz a consulta do alerta, restrita a este run (stdin: definições)
  check <run> <n_http> <n_amqp> <senha_errada>   linhas PASS/FAIL sobre as mensagens do run (stdin: busca)
"""
import json
import sys

STREAM = "RabbitMQ - Infra"
SMOKE_PREFIX = "NOT smoke_test:true AND "
INVALID = "invalid credentials"

failures = 0


def check(name, condition):
    """Registra o resultado de uma verificação."""
    global failures
    print(("PASS  " if condition else "FAIL  ") + name, flush=True)
    if not condition:
        failures += 1


def rows(search):
    """Converte a resposta de /api/search/messages em dicionários, sem duplicatas (o coletor entrega at least once)."""
    fields = [column["field"] for column in search.get("schema", [])]
    unique = {}
    for row in search.get("datarows", []):
        message = dict(zip(fields, row))
        unique[(message.get("time"), message.get("message"))] = message
    return list(unique.values())


def alert_search(definitions, title, run_id):
    """Corpo da busca com a consulta do alerta (sem o prefixo que exclui o smoke) e o stream dele, só deste run."""
    found = [d for d in definitions.get("event_definitions", []) if d.get("title") == title]
    if not found:
        sys.exit(f"alert not found: {title}")
    config = found[0]["config"]
    query = config["query"].removeprefix(SMOKE_PREFIX)
    return {"query": f'({query}) AND "{run_id}"', "streams": config["streams"],
            "timerange": {"type": "relative", "range": 900}, "size": 500, "fields": ["message", "time"]}


def failed_to_authenticate(user):
    return f"User '{user}' failed to authenticate: user '{user}' - {INVALID}"


def check_messages(messages, run_id, n_http, n_amqp, wrong_password):
    """Formato real dos logins recusados no RabbitMQ 4.3, roteamento e nível numérico."""
    prefix = f"e2e-nobody-{run_id}"
    http_users = [f"{prefix}-http-{i}" for i in range(1, n_http + 1)]
    amqp_users = [f"{prefix}-amqp-{i}" for i in range(1, n_amqp + 1)]
    level_probe = f"{prefix}-lvl-[info]"
    expected = 2 * (n_http + n_amqp + 1)
    check(f"Graylog has {expected} messages of this run (2 log lines per refused login: "
          f"{n_http} management + {n_amqp} AMQP + 1 level probe), found {len(messages)}", len(messages) == expected)

    check("every message has service_name=rabbitmq, tag=rabbitmq and source=rabbitmq",
          all(m.get("service_name") == "rabbitmq" and m.get("tag") == "rabbitmq" and m.get("source") == "rabbitmq"
              for m in messages))
    check(f"every message is only in the stream '{STREAM}' (not in any other stream)",
          all(m.get("streams") == [STREAM] for m in messages))
    check("every message keeps the broker event time (field time, 'YYYY-MM-DD HH:MM:SS.ffffff+00:00')",
          all(isinstance(m.get("time"), str) and m["time"].endswith("+00:00") and len(m["time"]) == 32 for m in messages))
    check("the wrong password does not appear in any message",
          all(wrong_password not in json.dumps(m) for m in messages))

    def matching(predicate):
        return [m for m in messages if predicate(m.get("message") or "")]

    for user in http_users:
        auth = matching(lambda text, u=user: text == failed_to_authenticate(u))
        denied = matching(lambda text, u=user: text == f"HTTP access denied: user '{u}' - {INVALID}")
        check(f"management refusal {user.removeprefix(prefix + '-')}: 1 'failed to authenticate' + 1 'HTTP access denied', both warning (4)",
              len(auth) == 1 and len(denied) == 1
              and all(m.get("level") == 4 and m.get("level_name") == "warning" for m in auth + denied))

    for user in amqp_users + [level_probe]:
        auth = matching(lambda text, u=user: text == failed_to_authenticate(u))
        refused = matching(lambda text, u=user: text.startswith("Error on AMQP connection <")
                           and text.endswith(f"\nPLAIN login refused: user '{u}' - {INVALID}"))
        check(f"AMQP refusal {user.removeprefix(prefix + '-')}: 1 'failed to authenticate' warning (4) + 1 'PLAIN login refused' error (3)",
              len(auth) == 1 and len(refused) == 1
              and all(m.get("level") == 4 and m.get("level_name") == "warning" for m in auth)
              and all(m.get("level") == 3 and m.get("level_name") == "error" for m in refused))


def main():
    command, args = sys.argv[1], sys.argv[2:]
    data = json.load(sys.stdin)
    if command == "count":
        print(len(rows(data)))
    elif command == "alert-search":
        print(json.dumps(alert_search(data, args[0], args[1])))
    elif command == "check":
        check_messages(rows(data), args[0], int(args[1]), int(args[2]), args[3])
        sys.exit(1 if failures else 0)
    else:
        sys.exit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
