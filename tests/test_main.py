import json
import logging

import pytest
from fastapi.testclient import TestClient
from prometheus_client import REGISTRY

from app.config import Settings, get_settings
from app.logging_config import JsonFormatter
from app.main import app, settings


@pytest.fixture()
def client():
    # Context manager triggers lifespan startup/shutdown.
    with TestClient(app) as c:
        yield c


def test_root_returns_expected_payload(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json() == {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": settings.app_version,
    }


def test_health_ok_when_started(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_health_503_before_startup():
    # Without the context manager, lifespan never runs -> not ready.
    from app import main

    main.state["ready"] = False
    resp = TestClient(app).get("/health")
    assert resp.status_code == 503


def test_metrics_exposes_prometheus_format(client):
    client.get("/")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")
    body = resp.text
    assert "http_requests_total" in body
    assert "http_errors_total" in body
    assert "http_request_duration_seconds_bucket" in body
    assert 'path="/"' in body


def test_unknown_route_uses_low_cardinality_label(client):
    client.get("/does-not-exist-12345")
    body = client.get("/metrics").text
    assert 'path="unmatched"' in body
    assert "does-not-exist-12345" not in body


def test_json_formatter_outputs_valid_json():
    record = logging.makeLogRecord({"name": "t", "levelname": "INFO", "msg": "hello", "path": "/x"})
    out = json.loads(JsonFormatter("test").format(record))
    assert out["message"] == "hello"
    assert out["level"] == "info"
    assert out["path"] == "/x"
    assert out["env"] == "test"


@pytest.fixture()
def failing_route():
    """Temporarily register a route that raises, to exercise the error path."""
    path = "/__test/boom"

    async def boom():
        raise RuntimeError("boom")

    app.add_api_route(path, boom)
    yield path
    app.router.routes[:] = [r for r in app.router.routes if getattr(r, "path", None) != path]


def test_unhandled_exception_is_counted_as_error(failing_route):
    labels = {"method": "GET", "path": failing_route}
    before = REGISTRY.get_sample_value("http_errors_total", labels) or 0.0

    with TestClient(app, raise_server_exceptions=False) as c:
        resp = c.get(failing_route)

    assert resp.status_code == 500
    assert REGISTRY.get_sample_value("http_errors_total", labels) == before + 1
    assert REGISTRY.get_sample_value("http_requests_total", {**labels, "status": "500"}) >= 1


def test_settings_read_from_environment(monkeypatch):
    monkeypatch.setenv("PORT", "9090")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("APP_VERSION", "1.2.3")

    expected = Settings(port=9090, log_level="DEBUG", environment="staging", app_version="1.2.3")
    assert get_settings() == expected
