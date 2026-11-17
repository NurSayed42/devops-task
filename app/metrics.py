"""Prometheus metrics definitions."""

from prometheus_client import Counter, Gauge, Histogram, disable_created_metrics

# `*_created` timestamp series double the series count and nothing queries them.
disable_created_metrics()

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)
ERROR_COUNT = Counter(
    "http_errors_total",
    "Total HTTP responses with status >= 500 or unhandled exceptions",
    ["method", "path"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
APP_INFO = Gauge(
    "app_info",
    "Static application info",
    ["version", "env"],
)
