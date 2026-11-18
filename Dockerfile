# syntax=docker/dockerfile:1.7

# Base image pinned by version AND multi-arch index digest (amd64 + arm64).
# Dependabot (docker ecosystem) keeps both FROM lines up to date.

# ---------- Stage 1: build dependencies ----------
FROM python:3.12.16-alpine3.24@sha256:c5ba3deef00c7758561a0f03c26f44f10589263d40e732b8748e0d1f38f6dd89 AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- Stage 2: minimal runtime ----------
FROM python:3.12.16-alpine3.24@sha256:c5ba3deef00c7758561a0f03c26f44f10589263d40e732b8748e0d1f38f6dd89 AS runtime

ARG APP_VERSION=0.1.0
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="devops-task-api" \
      org.opencontainers.image.description="FastAPI hello service for the DevOps assessment" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/NurSayed42/devops-task" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    LOG_LEVEL=INFO \
    APP_ENV=production \
    APP_VERSION=${APP_VERSION}

# pip is not needed at runtime. Removing it here does not save bytes (they stay in
# the base layer), but it is gone from the final filesystem: scanners stop
# reporting its CVEs and nothing in the container can install packages.
RUN pip uninstall -y pip \
 && addgroup -S -g 10001 app \
 && adduser -S -D -H -u 10001 -G app app

COPY --from=builder /install /usr/local
WORKDIR /srv
# Code stays root-owned (read-only for the runtime user), so a compromised
# process cannot modify the application it is running.
COPY app/ ./app/

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import os,urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.getenv(\"PORT\",\"8080\")}/health', timeout=2)"]

# Exec form: python is PID 1 and receives SIGTERM directly, so uvicorn can
# stop accepting connections and drain in-flight requests before exiting.
STOPSIGNAL SIGTERM
ENTRYPOINT ["python", "-m", "app.main"]
