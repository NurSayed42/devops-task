# DevOps Task API — Step 1: Application & Containerization

A small FastAPI service that is the base for the DevOps assessment.

## Endpoints

| Method | Path       | Description |
|--------|------------|-------------|
| GET    | `/`        | `{"message": "Hello from DevOps Task!", "status": "running", "version": "<APP_VERSION>"}` |
| GET    | `/health`  | Liveness/readiness check. `200 {"status":"ok"}` once started, `503` while starting/stopping |
| GET    | `/metrics` | Prometheus metrics |

### Metrics exposed
- `http_requests_total{method,path,status}` — request count
- `http_errors_total{method,path}` — 5xx / unhandled exceptions
- `http_request_duration_seconds` — latency histogram (p50/p95/p99 via `histogram_quantile`)
- `app_info{version,env}` — build info

`path` uses the **route template**, not the raw URL (unknown URLs → `unmatched`), so label cardinality stays bounded.

## Configuration (environment variables)

| Variable      | Default       | Purpose |
|---------------|---------------|---------|
| `PORT`        | `8080`        | Listen port |
| `LOG_LEVEL`   | `INFO`        | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `APP_ENV`     | `development` | Environment name (added to every log line) |
| `APP_VERSION` | `0.1.0`       | Reported by `/` and `app_info` |

## Logging
All logs (app + uvicorn) are single-line JSON on stdout, e.g.:
```json
{"timestamp":"...","level":"info","logger":"app","message":"request completed","env":"local","method":"GET","path":"/","status":200,"duration_ms":0.61}
```

## Graceful shutdown
The container runs `python -m app.main` in exec form, so Python is PID 1 and receives `SIGTERM` directly. Uvicorn stops accepting connections, drains in-flight requests (up to 20s), then the lifespan hook marks the app not-ready and logs shutdown. Compose `stop_grace_period` is 30s.

## Run locally

```bash
# Python
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m app.main            # http://localhost:8080

# Tests + coverage + lint
pytest
ruff check app tests

# Docker Compose
docker compose up --build -d
curl localhost:8080/ && curl localhost:8080/health && curl localhost:8080/metrics
docker compose ps             # shows (healthy)
```

## Dockerfile notes
- **Multi-stage**: builder installs deps into `/install`; runtime copies only that + `app/`.
- **Base pinned**: `python:3.12.8-alpine3.21` (pin to a digest in CI with `docker buildx imagetools inspect`).
- **Minimal**: Alpine; pip/setuptools removed from the final image.
- **Non-root**: UID/GID `10001`.
- **HEALTHCHECK** uses Python's `urllib` (no curl needed).
- **OCI labels** with version, git SHA, and build date passed as build args.
- Compose also runs it `read_only` with `/tmp` as tmpfs, `no-new-privileges`, CPU/memory limits, and `restart: unless-stopped`.

**Final image size:** _fill in after `docker images devops-task-api` (expected ~60–70 MB)._

```bash
docker build \
  --build-arg APP_VERSION=0.1.0 \
  --build-arg GIT_SHA=$(git rev-parse --short HEAD) \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  -t devops-task-api:0.1.0 .
```

## Project layout
```
app/
  main.py            # FastAPI app, middleware, endpoints, entrypoint
  config.py          # env-var config
  logging_config.py  # JSON logging
  metrics.py         # Prometheus metrics
tests/test_main.py   # unit tests
Dockerfile
.dockerignore
docker-compose.yml
requirements.txt / requirements-dev.txt
pyproject.toml       # pytest + ruff config
```
