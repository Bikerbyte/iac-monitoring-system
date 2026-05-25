FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

RUN useradd --system --uid 10001 --no-create-home agent

COPY --from=builder /install /usr/local
COPY agent/agent.py /app/agent.py
COPY agent/config.yml /etc/monitor-agent/config.yml

USER 10001
EXPOSE 8000

ENTRYPOINT ["python", "/app/agent.py"]
CMD ["--config", "/etc/monitor-agent/config.yml", "--log-file", ""]
