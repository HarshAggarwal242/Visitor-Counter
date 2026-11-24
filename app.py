"""
Visitor Counter Web Application
===============================

A very small Flask application that counts page visits in Redis.

How it works:
    1. A browser asks for "/".
    2. The app runs INCR on a Redis key (atomic, so concurrent visits are safe).
    3. The new total is rendered on a styled page.

Endpoints:
    GET /         -> homepage, increments the counter
    GET /health   -> detailed health check (verifies Redis connectivity, used by
                     the Kubernetes readiness probe). Returns HTTP 503 if Redis
                     cannot be reached.
    GET /healthz  -> tiny liveness check that only proves the Flask process is
                     alive (used by the Kubernetes liveness probe).

All configuration comes from environment variables, which is what lets the SAME
image run under Docker Compose and inside Kubernetes without any code change.
"""

import logging
import os
import socket
import time

import redis
from flask import Flask, jsonify, render_template_string

# ---------------------------------------------------------------------------
# Logging (Docker and Kubernetes both capture stdout, so we log there)
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
LOG = logging.getLogger("visitor-counter")

START_TIME = time.time()

# ---------------------------------------------------------------------------
# HTML page (kept inside app.py on purpose: the project stays small and there
# is no templates/ folder to lose track of)
# ---------------------------------------------------------------------------
PAGE_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Visitor Counter | Cloud Computing Project</title>
  <style>
    :root {
      --ink: #0f172a;
      --muted: #64748b;
      --line: #e2e8f0;
      --brand: #2563eb;
      --ok: #16a34a;
      --warn: #b45309;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 18px;
      padding: 24px;
      font-family: "Segoe UI", system-ui, -apple-system, Arial, sans-serif;
      color: var(--ink);
      background: radial-gradient(circle at 15% 15%, #dbeafe 0%, #eef2ff 40%, #f8fafc 100%);
    }
    .card {
      width: 100%;
      max-width: 560px;
      background: #ffffff;
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 36px 32px;
      text-align: center;
      box-shadow: 0 18px 45px rgba(15, 23, 42, 0.10);
    }
    .eyebrow {
      margin: 0 0 6px;
      font-size: 12px;
      letter-spacing: 0.16em;
      text-transform: uppercase;
      color: var(--brand);
      font-weight: 700;
    }
    h1 { margin: 0; font-size: 30px; letter-spacing: -0.02em; }
    .subtitle { margin: 8px 0 26px; color: var(--muted); font-size: 15px; }
    .counter {
      font-size: 68px;
      font-weight: 800;
      line-height: 1;
      letter-spacing: -0.04em;
      color: var(--ink);
      font-variant-numeric: tabular-nums;
    }
    .label { margin: 10px 0 0; color: var(--muted); font-size: 14px; }
    .alert {
      text-align: left;
      background: #fffbeb;
      border: 1px solid #fcd34d;
      border-radius: 12px;
      padding: 16px 18px;
      color: var(--warn);
      font-size: 14px;
    }
    .alert p { margin: 8px 0 0; color: #7c2d12; }
    .alert code { word-break: break-word; }
    .meta {
      display: flex;
      flex-wrap: wrap;
      justify-content: center;
      gap: 8px 22px;
      margin-top: 26px;
      padding-top: 18px;
      border-top: 1px solid var(--line);
      font-size: 13px;
      color: var(--muted);
    }
    .meta strong { color: var(--ink); font-weight: 600; }
    .button {
      display: inline-block;
      margin-top: 22px;
      padding: 11px 22px;
      border-radius: 10px;
      background: var(--brand);
      color: #ffffff;
      text-decoration: none;
      font-weight: 600;
      font-size: 14px;
    }
    .button:hover { background: #1d4ed8; }
    .links { margin: 18px 0 0; font-size: 13px; color: var(--muted); }
    .links a { color: var(--brand); text-decoration: none; }
    footer { font-size: 12px; color: var(--muted); text-align: center; }
  </style>
</head>
<body>
  <main class="card">
    <p class="eyebrow">Cloud Computing Project</p>
    <h1>Visitor Counter</h1>
    <p class="subtitle">Flask serves the page, Redis stores the visit count.</p>

    {% if error %}
      <div class="alert">
        <strong>Counter temporarily unavailable</strong>
        <p>The page is still being served, but Redis could not be reached.</p>
        <p><code>{{ error }}</code></p>
        <p>The counter recovers automatically as soon as Redis is reachable again.</p>
      </div>
    {% else %}
      <div class="counter">{{ "{:,}".format(count) }}</div>
      <p class="label">total visits recorded in Redis</p>
    {% endif %}

    <div class="meta">
      <span>Environment: <strong>{{ location }}</strong></span>
      <span>Pod / container: <strong>{{ pod_name }}</strong></span>
    </div>

    <a class="button" href="/">Count another visit</a>
    <p class="links"><a href="/health">/health</a> &middot; <a href="/healthz">/healthz</a></p>
  </main>
  <footer>Python &middot; Flask &middot; Redis &middot; Docker &middot; Kubernetes &middot; HPA</footer>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Small helpers for reading environment variables safely
# ---------------------------------------------------------------------------
def env_str(name: str, default: str) -> str:
    """Return an environment variable as text, or the default when unset/blank."""
    value = os.getenv(name)
    return value if value not in (None, "") else default


def env_int(name: str, default: int) -> int:
    """Return an environment variable as an int, falling back to the default."""
    try:
        return int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        LOG.warning("Invalid value for %s, using default %s", name, default)
        return default


def env_float(name: str, default: float) -> float:
    """Return an environment variable as a float, falling back to the default."""
    try:
        return float(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        LOG.warning("Invalid value for %s, using default %s", name, default)
        return default


def build_redis_client() -> redis.Redis:
    """
    Create the Redis client.

    Short socket timeouts matter: if Redis is down we want a fast, graceful
    error instead of a request that hangs until the proxy gives up.
    """
    return redis.Redis(
        host=env_str("REDIS_HOST", "localhost"),
        port=env_int("REDIS_PORT", 6379),
        db=env_int("REDIS_DB", 0),
        password=os.getenv("REDIS_PASSWORD") or None,
        decode_responses=True,
        socket_connect_timeout=env_float("REDIS_CONNECT_TIMEOUT", 2.0),
        socket_timeout=env_float("REDIS_SOCKET_TIMEOUT", 2.0),
        health_check_interval=30,
    )


def create_app(redis_client: "redis.Redis | None" = None) -> Flask:
    """
    Application factory.

    Passing redis_client is only used by the local smoke test; in normal runs
    the client is built from environment variables.
    """
    settings = {
        "location": env_str("APP_LOCATION", "local-laptop"),
        "pod_name": env_str("POD_NAME", socket.gethostname()),
        "counter_key": env_str("VISIT_COUNTER_KEY", "visitor:total"),
    }
    client = redis_client or build_redis_client()

    app = Flask(__name__)

    def render_page(count=None, error=None):
        """Render the homepage. Never raises, even when Redis is down."""
        return render_template_string(
            PAGE_TEMPLATE,
            count=count,
            error=error,
            location=settings["location"],
            pod_name=settings["pod_name"],
        )

    @app.get("/")
    def index():
        """Increment the visit counter and show the total."""
        try:
            count = int(client.incr(settings["counter_key"]))
            return render_page(count=count)
        except redis.RedisError as exc:
            # Graceful degradation: the visitor still gets a working page.
            LOG.warning("Redis unavailable while counting visit: %s", exc)
            return render_page(error=f"{type(exc).__name__}: {str(exc)[:180]}")

    @app.get("/healthz")
    def healthz():
        """Liveness: the process is up. Does NOT touch Redis."""
        return jsonify(
            {
                "status": "ok",
                "check": "liveness",
                "uptime_seconds": round(time.time() - START_TIME, 1),
            }
        )

    @app.get("/health")
    def health():
        """Readiness + Redis connectivity check."""
        payload = {
            "status": "ok",
            "check": "readiness",
            "redis": "ok",
            "environment": settings["location"],
            "pod": settings["pod_name"],
            "uptime_seconds": round(time.time() - START_TIME, 1),
        }
        try:
            client.ping()
            payload["visits"] = int(client.get(settings["counter_key"]) or 0)
            return jsonify(payload), 200
        except redis.RedisError as exc:
            LOG.warning("Redis health check failed: %s", exc)
            payload.update(
                status="degraded",
                redis="unavailable",
                error=f"{type(exc).__name__}: {str(exc)[:180]}",
            )
            return jsonify(payload), 503

    @app.get("/favicon.ico")
    def favicon():
        """Avoid noisy 404s (and wasted CPU) from browser favicon requests."""
        return "", 204

    @app.after_request
    def no_cache(response):
        """
        Never cache the page: otherwise a browser refresh could show an old
        count and the load test would not reach the app at all.
        """
        response.headers["Cache-Control"] = "no-store, max-age=0"
        return response

    return app


# Gunicorn entry point:  gunicorn app:app
app = create_app()


if __name__ == "__main__":
    # Local development only (Docker/Kubernetes run gunicorn instead).
    app.run(
        host=env_str("APP_HOST", "0.0.0.0"),
        port=env_int("APP_PORT", 5000),
        debug=False,
        threaded=True,
    )
