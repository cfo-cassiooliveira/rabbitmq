# Cliente de smoke AMQP descartável (pika). Python 3.13 alpine fixado por digest.
FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --disable-pip-version-check -r requirements.txt
COPY smoke.py ./
USER nobody
ENTRYPOINT ["python", "/app/smoke.py"]
