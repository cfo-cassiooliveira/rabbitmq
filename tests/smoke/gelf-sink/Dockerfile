# Destino GELF TCP descartável do smoke do fallback de logs. Python 3.13 alpine fixado por digest (mesma base do smoke AMQP).
FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
WORKDIR /app
COPY gelf-sink.py ./
# /data é volume nomeado (gravável pelo usuário nobody).
RUN mkdir /data && chown nobody /data
USER nobody
ENTRYPOINT ["python", "/app/gelf-sink.py"]
