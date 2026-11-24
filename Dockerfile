# ---------------------------------------------------------------------------
# Optimized image (this is the one the project uses).
#
# Why it is small / efficient:
#   * python:3.12-slim base instead of the full python:3.12 image (~1 GB).
#   * pip cache is not written (--no-cache-dir / PIP_NO_CACHE_DIR).
#   * requirements.txt is copied BEFORE app.py so code edits do not reinstall
#     dependencies (Docker layer cache).
#   * only the three packages we really need are installed (no test tools).
#   * runs as a non-root user and with gunicorn instead of the Flask dev server.
# ---------------------------------------------------------------------------
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_PORT=5000

WORKDIR /app

# Dependencies first: this layer stays cached when only app.py changes.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Application code.
COPY app.py ./

# Non-root user (matches runAsUser 10001 in k8s.yaml).
RUN useradd --create-home --uid 10001 appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

# Liveness endpoint only: it does not depend on Redis, so the container is not
# marked unhealthy just because Redis is restarting.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/healthz', timeout=2).getcode()==200 else 1)"

# gunicorn: 2 worker processes x 4 threads. Enough for a demo, small enough to
# let the HPA react to a 100m CPU request.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "4", "--timeout", "30", "--access-logfile", "-", "app:app"]
