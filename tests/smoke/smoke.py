"""Smoke AMQP ponta a ponta do broker (pika). Fases: main | persist-publish | persist-verify | cleanup | tls (AMQPS) | cadastro-permissions | cadastro-retry | cadastro-dlq.

Roda em container descartável (compose profile "smoke"), só com a credencial do smoke-app (sem acesso à API de
management; o estado das filas é verificado pelo scripts/smoke-test.sh). Nada sensível é impresso.
Usa a topologia de smoke das definitions (smoke.events, smoke-consumer.ping e a DLQ) e uma fila temporária
smoke-consumer.t<runid>, removida ao final. Cada fase imprime linhas PASS/FAIL e sai com código != 0 se algo falhar.
"""
import json
import os
import socket
import ssl
import sys
import time
import uuid

import pika
from pika import exceptions as pe

HOST = os.environ.get("AMQP_HOST", "rabbitmq")
VHOST = "dev"
EXCHANGE = "smoke.events"
PING_QUEUE = "smoke-consumer.ping"
DLQ = "smoke-consumer.ping.dlq"
ROUTING_KEY = "smoke.ping.sent.v1"
RUN_ID = uuid.uuid4().hex[:8]
TEMP_QUEUE = f"smoke-consumer.t{RUN_ID}"

failures = 0


def check(name, condition):
    """Registra o resultado de uma verificação."""
    global failures
    print(("PASS  " if condition else "FAIL  ") + name, flush=True)
    if not condition:
        failures += 1


def connect(user, password, retries=1):
    """Abre conexão no vhost dev; com retries > 1 tenta de novo (reconexão após restart do broker)."""
    params = pika.ConnectionParameters(
        host=HOST, virtual_host=VHOST, credentials=pika.PlainCredentials(user, password),
        heartbeat=30, blocked_connection_timeout=30, connection_attempts=1, socket_timeout=5,
    )
    last = None
    for _ in range(retries):
        try:
            return pika.BlockingConnection(params)
        except (pe.AMQPError, OSError) as exc:  # noqa: PERF203
            last = exc
            time.sleep(3)
    raise last


def smoke_app():
    return connect("smoke-app", os.environ["SMOKE_APP_PASSWORD"], retries=int(os.environ.get("CONNECT_RETRIES", "1")))


def login_rejected(user, password):
    """True só se o broker recusa a credencial; broker fora ou outro erro NÃO conta como recusa."""
    try:
        connect(user, password).close()
    except (pe.ProbableAuthenticationError, pe.ProbableAccessDeniedError):
        return True
    except (pe.AMQPError, OSError) as exc:
        print(f"      unexpected error instead of a credential rejection: {type(exc).__name__}", flush=True)
        return False
    return False


def purge_fixed_queues(channel):
    """Esvazia as filas fixas de smoke (idempotência entre execuções)."""
    for queue in (PING_QUEUE, DLQ):
        channel.queue_purge(queue)


def publish(channel, key, body, mandatory=True):
    """Publica persistente com confirm; levanta UnroutableError/NackError se não confirmado/roteado."""
    channel.basic_publish(
        EXCHANGE, key, body,
        pika.BasicProperties(delivery_mode=2, content_type="application/json", message_id=str(uuid.uuid4())),
        mandatory=mandatory,
    )


def get_one(channel, queue, timeout=15):
    """Lê uma mensagem sem auto-ack (basic_get com tentativas curtas); o chamador decide ack/nack."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        method, props, body = channel.basic_get(queue, auto_ack=False)
        if method:
            return method, props, body
        time.sleep(0.5)
    return None, None, None


def raises_access_refused(action):
    """Executa action numa conexão nova e confirma que o broker fecha o canal com 403 (ACCESS_REFUSED)."""
    connection = smoke_app()
    try:
        channel = connection.channel()
        action(channel)
    except pe.ChannelClosedByBroker as exc:
        return exc.reply_code == 403
    except pe.AMQPError:
        return False
    finally:
        if connection.is_open:
            connection.close()
    return False


def check_prefetch_and_manual_ack(connection):
    """Consumidor com prefetch 1 e ack manual: com 2 mensagens, só 1 é entregue até o ack da primeira."""
    channel = connection.channel()
    channel.confirm_delivery()
    channel.basic_qos(prefetch_count=1)
    bodies = [json.dumps({"messageId": f"{RUN_ID}-{n}"}).encode() for n in (1, 2)]
    for body in bodies:
        publish(channel, ROUTING_KEY, body)
    consumer = channel.consume(PING_QUEUE, auto_ack=False, inactivity_timeout=3)
    first_method, first_props, first_body = next(consumer)
    check("consumer receives the first message", first_body == bodies[0])
    check("delivered message is persistent (delivery_mode=2)", first_props is not None and first_props.delivery_mode == 2)
    second_method, _, _ = next(consumer)
    check("prefetch=1: second message is NOT delivered while the first is unacked", second_method is None)
    check("unacked message is held by the consumer (1 ready message left in the queue)",
          connection.channel().queue_declare(PING_QUEUE, passive=True).method.message_count == 1)
    channel.basic_ack(first_method.delivery_tag)
    second_method, _, second_body = next(consumer)
    check("after the ack the second message is delivered", second_body == bodies[1])
    channel.basic_ack(second_method.delivery_tag)
    channel.cancel()
    channel.close()
    # Mensagem sem ack voltaria à fila ao fechar o canal: fila vazia numa sessão nova prova que os acks valeram.
    verify = connection.channel()
    check("manual ack leaves nothing to redeliver after the channel closes",
          verify.queue_declare(PING_QUEUE, passive=True).method.message_count == 0)
    verify.close()


def phase_main():
    connection = smoke_app()
    try:
        _run_main(connection)
    finally:
        # Remove a fila temporária mesmo se uma verificação levantar exceção.
        cleanup_connection = connection if connection.is_open else smoke_app()
        try:
            cleanup_connection.channel().queue_delete(TEMP_QUEUE)
        except pe.AMQPError:
            pass
        if cleanup_connection.is_open:
            cleanup_connection.close()


def _run_main(connection):
    channel = connection.channel()
    channel.confirm_delivery()
    purge_fixed_queues(channel)

    body = json.dumps({"messageId": RUN_ID, "type": ROUTING_KEY}).encode()
    try:
        publish(channel, ROUTING_KEY, body)
        confirmed = True
    except (pe.UnroutableError, pe.NackError):
        confirmed = False
    check("publish with confirm + mandatory is confirmed and routed", confirmed)
    method, _, received = get_one(channel, PING_QUEUE)
    check("message is delivered with the same body", received == body)
    if method:
        channel.basic_ack(method.delivery_tag)
    channel.close()

    # Prefetch efetivo e ack manual com consumidor de verdade (basic_consume).
    check_prefetch_and_manual_ack(connection)

    # nack(requeue=false) -> DLX -> DLQ, com o header x-death.
    channel = connection.channel()
    channel.confirm_delivery()
    publish(channel, ROUTING_KEY, body)
    method, _, _ = get_one(channel, PING_QUEUE)
    if method:
        channel.basic_nack(method.delivery_tag, requeue=False)
    method, props, dead = get_one(channel, DLQ)
    check("nack(requeue=false) dead-letters the message to the DLQ", dead == body)
    death = ((props.headers or {}).get("x-death") or [{}])[0] if props else {}
    check("DLQ message has x-death with reason=rejected", death.get("reason") == "rejected")
    check("DLQ message has x-death with the source queue", death.get("queue") == PING_QUEUE)
    if method:
        channel.basic_ack(method.delivery_tag)
    check("source queue is empty after the nack", channel.queue_declare(PING_QUEUE, passive=True).method.message_count == 0)

    # Rota inexistente: mandatory devolve a mensagem (basic.return).
    try:
        publish(channel, "smoke.nobody.listens.v1", body)
        returned = False
    except pe.UnroutableError:
        returned = True
    check("unroutable message is returned (mandatory / basic.return)", returned)

    # Fila temporária dentro do prefixo: usa binding no exchange de smoke.
    channel.queue_declare(TEMP_QUEUE, durable=True, arguments={"x-queue-type": "quorum"})
    channel.queue_bind(TEMP_QUEUE, EXCHANGE, f"smoke.temp.{RUN_ID}.v1")
    publish(channel, f"smoke.temp.{RUN_ID}.v1", body)
    method, _, temp_body = get_one(channel, TEMP_QUEUE)
    check("temporary quorum queue inside the prefix works end to end", temp_body == body)
    if method:
        channel.basic_ack(method.delivery_tag)

    # Permissões: fora do prefixo é negado (403); guest e senha errada são recusados (e só por credencial).
    check("declaring a queue outside the prefix is denied (403)",
          raises_access_refused(lambda ch: ch.queue_declare("orders.forbidden", durable=True)))
    check("declaring an exchange outside the prefix is denied (403)",
          raises_access_refused(lambda ch: ch.exchange_declare("orders.events", exchange_type="topic", durable=True)))
    check("publishing to a foreign exchange is denied (403)",
          raises_access_refused(lambda ch: (ch.basic_publish("amq.topic", "x", b"x"), ch.queue_declare("smoke.sync", passive=True))))
    check("guest is rejected over AMQP (credential rejection)", login_rejected("guest", "guest"))
    check("wrong password is rejected over AMQP (credential rejection)", login_rejected("smoke-app", "wrong-password"))


def phase_persist_publish():
    """Deixa uma mensagem persistente na fila para ser verificada depois do restart do broker."""
    connection = smoke_app()
    channel = connection.channel()
    channel.confirm_delivery()
    purge_fixed_queues(channel)
    try:
        publish(channel, ROUTING_KEY, b"persist-check")
        confirmed = True
    except (pe.UnroutableError, pe.NackError):
        confirmed = False
    check("persistent message published and confirmed before the restart", confirmed)
    connection.close()


def phase_persist_verify():
    """Reconecta (com retries) após o restart e confere que a mensagem persistente sobreviveu."""
    os.environ["CONNECT_RETRIES"] = "40"
    connection = smoke_app()
    check("client reconnects after the broker restart", connection.is_open)
    channel = connection.channel()
    method, _, body = get_one(channel, PING_QUEUE)
    check("persistent message survived the broker restart", body == b"persist-check")
    if method:
        channel.basic_ack(method.delivery_tag)
    connection.close()


def phase_cleanup():
    """Esvazia as filas fixas (filas temporárias órfãs são removidas pelo scripts/smoke-test.sh, que tem a API)."""
    connection = smoke_app()
    channel = connection.channel()
    purge_fixed_queues(channel)
    time.sleep(1)
    check("fixed smoke queues are empty", all(channel.queue_declare(q, passive=True).method.message_count == 0 for q in (PING_QUEUE, DLQ)))
    connection.close()


CADASTRO_EVENTS = "cadastro.events"
CADASTRO_RETRY = "cadastro.retry"
CADASTRO_QUEUE = "cadastro.user-import-lines"
CADASTRO_KEY = "cadastro.user-import-line.accepted.v1"


def cadastro_app():
    return connect("cadastro-app", os.environ["CADASTRO_APP_PASSWORD"],
                   retries=int(os.environ.get("CONNECT_RETRIES", "1")))


def cadastro_publish(channel, exchange, body, expiration=None):
    """Publica persistente, com confirm e mandatory, como o relay do Cadastro faz."""
    channel.basic_publish(
        exchange, CADASTRO_KEY, body,
        pika.BasicProperties(delivery_mode=2, content_type="application/json", expiration=expiration),
        mandatory=True,
    )


def refused_for_cadastro(action, confirm=False):
    """Executa action numa conexão nova do cadastro-app e confirma o fechamento do canal com 403.

    Com confirm=True o canal usa publisher confirms: a recusa de um publish chega de forma síncrona."""
    connection = cadastro_app()
    try:
        channel = connection.channel()
        if confirm:
            channel.confirm_delivery()
        action(channel)
    except pe.ChannelClosedByBroker as exc:
        return exc.reply_code == 403
    except pe.AMQPError:
        return False
    finally:
        if connection.is_open:
            connection.close()
    return False


def phase_cadastro_permissions():
    """Permissões exatas do cadastro-app: publica nos exchanges permitidos, lê só a fila principal, nada de configure."""
    connection = cadastro_app()
    channel = connection.channel()
    channel.confirm_delivery()
    channel.queue_purge(CADASTRO_QUEUE)
    body = f"cadastro-{RUN_ID}".encode()
    cadastro_publish(channel, CADASTRO_EVENTS, body)
    method, _, received = get_one(channel, CADASTRO_QUEUE)
    check("cadastro-app publishes to cadastro.events and consumes cadastro.user-import-lines", received == body)
    if method:
        channel.basic_ack(method.delivery_tag)
    connection.close()

    # Sem configure: publish e consume acima não declararam nada; a declaração passiva também precisa funcionar.
    passive_connection = cadastro_app()
    try:
        passive_connection.channel().queue_declare(CADASTRO_QUEUE, passive=True)
        passive_ok = True
    except pe.AMQPError:
        passive_ok = False
    finally:
        if passive_connection.is_open:
            passive_connection.close()
    check("cadastro-app passive declare of the main queue works without configure", passive_ok)

    # Publish isolado (sem declaração depois): o 403 só pode vir da permissão de write.
    check("cadastro-app cannot publish to cadastro.dlx (403 from write, confirm + mandatory)",
          refused_for_cadastro(lambda ch: ch.basic_publish("cadastro.dlx", "x", b"x", mandatory=True), confirm=True))
    check("cadastro-app cannot publish to smoke.events (403 from write, confirm + mandatory)",
          refused_for_cadastro(lambda ch: ch.basic_publish("smoke.events", "x", b"x", mandatory=True), confirm=True))
    check("cadastro-app cannot declare a queue with the prefix (configure denied, 403)",
          refused_for_cadastro(lambda ch: ch.queue_declare("cadastro.rogue")))
    check("cadastro-app cannot declare an exchange (configure denied, 403)",
          refused_for_cadastro(lambda ch: ch.exchange_declare("cadastro.rogue", "topic")))
    check("cadastro-app cannot bind a queue (403)",
          refused_for_cadastro(lambda ch: ch.queue_bind(CADASTRO_QUEUE, CADASTRO_EVENTS, "rogue.#")))
    check("cadastro-app cannot read the retry queue (403)",
          refused_for_cadastro(lambda ch: ch.basic_get("cadastro.user-import-lines.retry")))
    check("cadastro-app cannot read the DLQ (403)",
          refused_for_cadastro(lambda ch: ch.basic_get("cadastro.user-import-lines.dlq")))
    check("cadastro-app cannot read smoke queues (403)",
          refused_for_cadastro(lambda ch: ch.basic_get(PING_QUEUE)))
    check("cadastro-app cannot delete the main queue (403)",
          refused_for_cadastro(lambda ch: ch.queue_delete(CADASTRO_QUEUE)))


def phase_cadastro_retry():
    """Retry: a mensagem republicada em cadastro.retry volta à fila principal depois do TTL (expiration curta no teste)."""
    connection = cadastro_app()
    channel = connection.channel()
    channel.confirm_delivery()
    channel.queue_purge(CADASTRO_QUEUE)
    body = f"retry-{RUN_ID}".encode()
    cadastro_publish(channel, CADASTRO_EVENTS, body)
    method, _, received = get_one(channel, CADASTRO_QUEUE)
    check("retry: message is delivered from the main queue", received == body)
    # Falha transitória: o consumidor republica no exchange de retry e confirma a original (padrão do plano).
    cadastro_publish(channel, CADASTRO_RETRY, body, expiration="1000")
    if method:
        channel.basic_ack(method.delivery_tag)
    check("retry: main queue is empty right after the retry publish",
          channel.basic_get(CADASTRO_QUEUE, auto_ack=False)[0] is None)
    method, _, again = get_one(channel, CADASTRO_QUEUE, timeout=20)
    check("retry: message returns to the main queue after the TTL (dead-letter via cadastro.events)", again == body)
    if method:
        channel.basic_ack(method.delivery_tag)
    connection.close()


def phase_cadastro_dlq():
    """DLQ: nack sem requeue e delivery-limit esgotado levam a mensagem à DLQ (conferida pela API no smoke-test.sh)."""
    connection = cadastro_app()
    channel = connection.channel()
    channel.confirm_delivery()
    channel.queue_purge(CADASTRO_QUEUE)
    cadastro_publish(channel, CADASTRO_EVENTS, f"reject-{RUN_ID}".encode())
    method, _, _ = get_one(channel, CADASTRO_QUEUE)
    check("dlq: message to be rejected is delivered", method is not None)
    if method:
        channel.basic_nack(method.delivery_tag, requeue=False)
    cadastro_publish(channel, CADASTRO_EVENTS, f"poison-{RUN_ID}".encode())
    deliveries = 0
    # Mensagem que nunca é confirmada: o canal fecha com a entrega pendente (devolução). O nack com requeue=true não
    # conta no delivery-limit do 4.x, só a devolução por canal/conexão fechada. Ao passar de 5 devoluções, o broker faz
    # o dead-letter (operator policy cadastro-limits): 1 entrega + 5 devoluções = 6 entregas.
    for _ in range(12):
        attempt = connection.channel()
        attempt.basic_qos(prefetch_count=1)
        method, _, _ = get_one(attempt, CADASTRO_QUEUE, timeout=3)
        if method is None:
            break
        deliveries += 1
        attempt.close()
    check("dlq: poison message is dead-lettered after the delivery limit (6 deliveries)", deliveries == 6)
    connection.close()


def _tls_context(minimum=None, maximum=None):
    """Contexto TLS que verifica o servidor contra a CA local (AMQP_TLS_CA) e o nome do host."""
    context = ssl.create_default_context(cafile=os.environ["AMQP_TLS_CA"])
    if minimum is not None:
        context.minimum_version = minimum
    if maximum is not None:
        context.maximum_version = maximum
    return context


def _handshake(context, server_hostname):
    """Faz só o handshake TLS no porto AMQPS; devolve (versão, cifra) ou levanta ssl.SSLError/OSError."""
    port = int(os.environ.get("AMQP_TLS_PORT", "5671"))
    with socket.create_connection((HOST, port), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname=server_hostname) as tls:
            return tls.version(), tls.cipher()[0]


def _amqps_connect(user, password, context, server_hostname=None):
    params = pika.ConnectionParameters(
        host=HOST, port=int(os.environ.get("AMQP_TLS_PORT", "5671")), virtual_host=VHOST,
        credentials=pika.PlainCredentials(user, password), connection_attempts=1, socket_timeout=5,
        ssl_options=pika.SSLOptions(context, server_hostname or HOST),
    )
    return pika.BlockingConnection(params)


def _fails(action):
    """True se a ação levanta erro de TLS/conexão/AMQP (a recusa esperada)."""
    try:
        action()
    except (ssl.SSLError, pe.AMQPError, OSError):
        return True
    return False


def phase_tls():
    """AMQPS (profile tls): verificação de peer contra a CA local, TLS >= 1.2, sem cifras fracas e sem texto plano forçado."""
    password = os.environ["SMOKE_APP_PASSWORD"]
    context = _tls_context()
    connection = _amqps_connect("smoke-app", password, context)
    channel = connection.channel()
    check("AMQPS connection verifies the server certificate (CA + hostname) and opens a channel", channel.is_open)
    check("smoke queue is reachable over AMQPS (quorum, passive declare)", channel.queue_declare(PING_QUEUE, passive=True).method.queue == PING_QUEUE)
    connection.close()
    version, cipher = _handshake(context, HOST)
    check(f"negotiated protocol is TLS 1.2 or newer ({version})", version in ("TLSv1.2", "TLSv1.3"))
    check("negotiated cipher is not weak (no RC4, 3DES, NULL, EXPORT, MD5)", not any(w in cipher for w in ("RC4", "3DES", "NULL", "EXPORT", "MD5")))
    tls12_version, _ = _handshake(_tls_context(ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_2), HOST)
    check("TLS 1.2 is accepted (compatibility)", tls12_version == "TLSv1.2")
    old = _tls_context(ssl.TLSVersion.TLSv1, ssl.TLSVersion.TLSv1_1)
    old.set_ciphers("ALL:@SECLEVEL=0")
    check("TLS 1.0/1.1 is refused", _fails(lambda: _handshake(old, HOST)))
    system_trust = ssl.create_default_context()
    check("connection without the local CA is refused (peer verification is real)", _fails(lambda: _amqps_connect("smoke-app", password, system_trust)))
    check("connection with a wrong server hostname is refused", _fails(lambda: _amqps_connect("smoke-app", password, context, "wrong.example")))
    check("guest is refused over AMQPS", _fails(lambda: _amqps_connect("guest", "guest", context)))
    check("wrong smoke-app password is refused over AMQPS", _fails(lambda: _amqps_connect("smoke-app", "wrong-password", context)))


PHASES = {"main": phase_main, "persist-publish": phase_persist_publish,
          "persist-verify": phase_persist_verify, "cleanup": phase_cleanup, "tls": phase_tls,
          "cadastro-permissions": phase_cadastro_permissions, "cadastro-retry": phase_cadastro_retry,
          "cadastro-dlq": phase_cadastro_dlq}

if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "main"
    if name not in PHASES:
        sys.exit(f"unknown phase: {name}")
    try:
        PHASES[name]()
    except Exception as exc:  # noqa: BLE001 - qualquer falha inesperada reprova a fase (sem credenciais na mensagem)
        print(f"FAIL  phase {name} raised {type(exc).__name__}: {exc}", flush=True)
        failures += 1
    sys.exit(1 if failures else 0)
