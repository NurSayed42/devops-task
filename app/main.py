"""Hello-world FastAPI service for the DevOps assessment."""

import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.config import get_settings
from app.logging_config import setup_logging
from app.metrics import APP_INFO, ERROR_COUNT, REQUEST_COUNT, REQUEST_LATENCY

settings = get_settings()
setup_logging(settings.log_level, settings.environment)
logger = logging.getLogger("app")

state = {"ready": False}


@asynccontextmanager
async def lifespan(_: FastAPI):
    APP_INFO.labels(version=settings.app_version, env=settings.environment).set(1)
    state["ready"] = True
    logger.info("application started", extra={"version": settings.app_version, "port": settings.port})
    yield
    # Runs when uvicorn receives SIGTERM/SIGINT: it stops accepting new
    # connections, drains in-flight requests, then calls this.
    state["ready"] = False
    logger.info("shutdown signal received, application stopped cleanly")


app = FastAPI(title="DevOps Task API", version=settings.app_version, lifespan=lifespan)


def _route_path(request: Request) -> str:
    """Use the route template (not the raw URL) to keep metric cardinality low."""
    route = request.scope.get("route")
    return getattr(route, "path", "unmatched")


@app.middleware("http")
async def observe_requests(request: Request, call_next):
    start = time.perf_counter()
    method = request.method
    try:
        response = await call_next(request)
    except Exception:
        # Handled here rather than re-raised: re-raising made uvicorn log the
        # same failure a second time ("Exception in ASGI application"), so every
        # error appeared twice in the logs. One structured line, with traceback.
        logger.exception("unhandled exception", extra={"method": method, "path": _route_path(request)})
        response = JSONResponse(status_code=500, content={"detail": "Internal Server Error"})

    duration = time.perf_counter() - start
    path = _route_path(request)
    status = response.status_code
    if path != "/metrics":
        REQUEST_COUNT.labels(method, path, str(status)).inc()
        REQUEST_LATENCY.labels(method, path).observe(duration)
        if status >= 500:
            ERROR_COUNT.labels(method, path).inc()
    logger.info(
        "request completed",
        extra={
            "method": method,
            "path": path,
            "status": status,
            "duration_ms": round(duration * 1000, 2),
            "client_ip": request.client.host if request.client else None,
        },
    )
    return response


@app.get("/")
async def root():
    return {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": settings.app_version,
    }


@app.get("/health")
async def health():
    if not state["ready"]:
        return JSONResponse(status_code=503, content={"status": "starting"})
    return {"status": "ok"}


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


def register_fault_injection(target: FastAPI) -> None:
    """GET /debug/fail raises, to exercise error metrics, logs, dashboards and alerts.

    Only registered when FAULT_INJECTION=true; otherwise the route does not exist (404).
    """

    @target.get("/debug/fail", include_in_schema=False)
    async def debug_fail():
        raise RuntimeError("fault injected via /debug/fail")


if settings.fault_injection:
    register_fault_injection(app)
    logger.warning("fault injection enabled: GET /debug/fail returns 500")


def run() -> None:
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=settings.port,
        log_config=None,  # keep our JSON logging
        access_log=False,
        timeout_graceful_shutdown=20,
        # Keep idle connections open longer than any proxy in front keeps them
        # (Envoy, AWS ALB: 60s). With uvicorn's default of 5s the app closes a
        # pooled connection the proxy is about to reuse, and that request fails
        # with a 502/503 (seen as Envoy "UC" during a rollout test).
        timeout_keep_alive=65,
        proxy_headers=True,
    )


if __name__ == "__main__":
    run()
