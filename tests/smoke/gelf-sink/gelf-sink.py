"""Destino GELF TCP de teste: grava cada mensagem recebida em /data/received.jsonl (uma por linha).

O GELF sobre TCP separa as mensagens por um byte nulo. Somente para o smoke do fallback de logs.
"""
import os
import socketserver
import threading

OUTPUT = os.environ.get("SINK_OUTPUT", "/data/received.jsonl")
PORT = int(os.environ.get("SINK_PORT", "12201"))
lock = threading.Lock()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        buffer = b""
        while True:
            chunk = self.request.recv(65536)
            if not chunk:
                break
            buffer += chunk
            *messages, buffer = buffer.split(b"\0")
            if messages:
                with lock, open(OUTPUT, "ab") as out:
                    for message in messages:
                        if message.strip():
                            out.write(message.strip() + b"\n")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("0.0.0.0", PORT), Handler) as server:
        server.serve_forever()
