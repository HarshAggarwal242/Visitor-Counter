# Visitor Counter on Docker and Kubernetes — Hybrid Cloud Simulation with HPA and Cost Optimization

**Cloud Computing** project: a Flask visitor counter
backed by Redis, deployed with **Docker Compose** and then on **Kubernetes
(Minikube)**, autoscaled with a **Horizontal Pod Autoscaler**, demonstrated across
**two Minikube clusters** with a working **failover script**, and optimized with
**three measured cost techniques**.

---

## Table of contents

1. [What the application does](#1-what-the-application-does)
2. [What the project demonstrates](#2-what-the-project-demonstrates)
3. [Project structure](#3-project-structure)
4. [Prerequisites](#4-prerequisites)
5. [Phase 1 — Run the app locally](#5-phase-1--run-the-app-locally)
6. [Phase 2 — Docker and Docker Compose](#6-phase-2--docker-and-docker-compose)
7. [Phase 3 — Kubernetes with Minikube](#7-phase-3--kubernetes-with-minikube)
8. [Phase 4 — Self-healing](#8-phase-4--self-healing)
9. [Phase 5 — HPA autoscaling](#9-phase-5--hpa-autoscaling)
10. [Phase 6 — Hybrid cloud simulation and failover](#10-phase-6--hybrid-cloud-simulation-and-failover)

---

## 1. What the application does

A browser opens `http://localhost:8080`. Flask runs `INCR` on a Redis key and
renders the new total. The page also shows **which environment** and **which Pod**
served the request, which is what makes autoscaling and failover visible.

| Endpoint | Purpose |
|----------|---------|
| `/` | Increments the counter and renders the page |
| `/health` | Readiness + Redis connectivity check (HTTP 503 when Redis is down) |
| `/healthz` | Liveness only (never touches Redis) |

If Redis is unreachable, the page still loads with a clear warning instead of an
error: the app degrades gracefully and recovers automatically.

Configuration is entirely environment-driven (`REDIS_HOST`, `REDIS_PORT`,
`REDIS_PASSWORD`, `VISIT_COUNTER_KEY`, `APP_LOCATION`, `POD_NAME`, `APP_PORT`),
so the **same image** runs under Compose and Kubernetes.

## 2. What the project demonstrates

| Requirement | How it is satisfied | Evidence to capture |
|-------------|--------------------|---------------------|
| Containerization | `Dockerfile` (slim, non-root, gunicorn), `.dockerignore` | `docker images`, `docker compose ps` |
| Compose networking + persistence | `docker-compose.yml`, named volume `redis-data` | count survives `down` / `up` |
| Kubernetes deployment | `k8s.yaml`: Deployments, Services, ConfigMap, Secret, PVC, probes, requests/limits | `kubectl get pods,deploy,svc` |
| Self-healing | `kubectl delete pod` → Deployment recreates it | `kubectl get pods -w` |
| HPA autoscaling | `hpa.yaml` (50% CPU, 2–5 replicas) + metrics-server | `kubectl get hpa`, replica changes |
| Hybrid cloud | two clusters: `vc-primary`, `vc-secondary` | `minikube profile list` |
| Failover | `failover/failover.ps1` moves the active endpoint | script output + page environment |
| Cost optimization | image size, right-sizing, replicas — measured by `scripts/measure.ps1` | `reports/cost_analysis.csv` |

## 3. Project structure

```text
visitor-counter-cloud-project/
├── app.py                  Flask application
├── requirements.txt        Flask, redis-py, gunicorn (pinned)
├── Dockerfile              optimized image
├── Dockerfile.baseline     naive image, used only for the size comparison
├── docker-compose.yml      Flask + Redis + volume + health checks
├── .dockerignore
├── .gitignore
├── k8s.yaml                Secret, ConfigMap, PVC, Deployments, Services
├── k8s-before.yaml         over-provisioned baseline (cost Technique 2/3)
├── hpa.yaml                Horizontal Pod Autoscaler
├── loadtest.yaml           optional in-cluster load generator
├── load_test.py            load generator / latency measurement (stdlib only)
├── failover/
│   ├── failover.ps1        failover, recovery, watch
├── scripts/
│   ├── setup.ps1           prerequisites, clusters, image, manifests
│   ├── start.ps1           start Compose or Kubernetes
│   ├── stop.ps1            stop and clean up
│   ├── verify.ps1          read-only PASS/FAIL checks
│   ├── measure.ps1         measures the 3 optimizations → cost_analysis.csv
│   ├── make_architecture.py  regenerates reports/architecture.png
│   └── build_report_pdf.py   regenerates reports/project_report.pdf
├── screenshots/            screenshots
├── reports/
│   ├── architecture.png
│   ├── project_report.md   report source
│   └── cost_analysis.csv   measured before/after values
├── github_link.txt         public repository URL
└── README.md
```

## 4. Prerequisites

Install once (Windows 11 PowerShell):

```powershell
winget install --id Docker.DockerDesktop -e
winget install --id Kubernetes.minikube -e
winget install --id Kubernetes.kubectl -e
winget install --id Python.Python.3.12 -e
```

Then:

1. Start **Docker Desktop** and wait until it reports *Engine running*.
2. In Docker Desktop → **Settings → Resources**, assign at least **6 GB RAM** and
   **4 CPUs** (two Minikube clusters need this).
3. Close and reopen PowerShell so the new tools are on `PATH`.
4. Verify:

```powershell
docker version --format '{{.Server.Version}}'
docker compose version
kubectl version --client
minikube version
python --version
```

> Docker Desktop uses WSL 2 on Windows 11. Minikube is started with the
> `--driver=docker` driver, as the assignment requires.

## 5. Phase 1 — Run the app locally

Redis is required. The simplest way is a single Redis container:

```powershell
docker run -d --name vc-redis -p 6379:6379 --requirepass change-me-redis redis:7-alpine

python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

$env:REDIS_PASSWORD = "change-me-redis"
$env:APP_LOCATION   = "local-laptop"
python app.py
```

Open <http://localhost:5000>. Refresh a few times: the number increases by one each
time. Check the machine-readable health data:

```powershell
Invoke-RestMethod http://localhost:5000/health | ConvertTo-Json
```

Expected output resembles:

```json
{
  "status": "ok",
  "check": "readiness",
  "redis": "ok",
  "environment": "local-laptop",
  "pod": "DESKTOP-XXXX",
  "uptime_seconds": 21.7,
  "visits": 4
}
```

## 6. Phase 2 — Docker and Docker Compose

```powershell
# Build the optimized image
docker build -t visitor-counter:optimized .
docker images visitor-counter

# Start Flask + Redis
docker compose up -d --build

# Status and logs
docker compose ps
docker compose logs -f flask
```

Expected: two containers, both `healthy` (Redis first, Flask waits for it because
of `depends_on: condition: service_healthy`). Open <http://localhost:8080>.

Verify Redis connectivity and persistence:

```powershell
# Is Redis answering, and what is the counter key?
docker exec visitor-counter-redis redis-cli --no-auth-warning -a change-me-redis ping
docker exec visitor-counter-redis redis-cli --no-auth-warning -a change-me-redis get visitor:total

# Restart everything: the count must NOT reset (named volume)
docker compose down
docker compose up -d
docker exec visitor-counter-redis redis-cli --no-auth-warning -a change-me-redis get visitor:total

# Image size (cost Technique 1, "after" value)
docker image inspect visitor-counter:optimized --format "{{.Size}}"
```

Other useful commands:

```powershell
docker compose stop
docker compose down            # keeps the volume
docker compose down -v         # deletes the volume (counter resets)
```

### Docker files at a glance

| File | Why it exists |
|------|---------------|
| `Dockerfile` | `python:3.12-slim`, dependencies copied before code (layer cache), no pip cache, non-root user `appuser`, gunicorn, `HEALTHCHECK` on `/healthz` |
| `Dockerfile.baseline` | The naive version (full `python:3.12`, pip cache, root, dev server) used **only** to measure the "before" image size |
| `.dockerignore` | Keeps the build context small (no git, venv, screenshots, docs) |
| `docker-compose.yml` | Two services on `visitor-counter-net`, health checks, `redis-data:/data`, resource limits |

## 7. Phase 3 — Kubernetes with Minikube

### 7.1 Start the primary cluster and load the image

```powershell
minikube start -p vc-primary --driver=docker --cpus=4 --memory=6144
minikube -p vc-primary addons enable metrics-server
minikube -p vc-primary image load visitor-counter:optimized
kubectl --context vc-primary get nodes
```

`minikube image load` matters: with the Docker driver the cluster has its own
image store, so an image built on the host is invisible to it without this step.
`k8s.yaml` therefore uses `imagePullPolicy: IfNotPresent` and no registry.

### 7.2 Deploy

```powershell
kubectl --context vc-primary apply -f k8s.yaml
kubectl --context vc-primary apply -f hpa.yaml

kubectl --context vc-primary get pods
kubectl --context vc-primary get deployments
kubectl --context vc-primary get services
kubectl --context vc-primary get pvc
```

Wait until every Pod shows `Running` with `1/1` ready and `READY 2/2` on the Flask
Deployment. Then access the application:

```powershell
# Option A - Minikube tunnel (keep the window open)
minikube -p vc-primary service visitor-counter --url

# Option B - port-forward (used by the failover script)
kubectl --context vc-primary port-forward svc/visitor-counter 8080:80
```

Open <http://localhost:8080>. The footer shows
`primary-simulated-private-cloud` and a Pod name.

Useful inspections:

```powershell
kubectl --context vc-primary describe deployment visitor-counter
kubectl --context vc-primary logs -l app=visitor-counter --tail=50
kubectl --context vc-primary exec deploy/redis -- redis-cli --no-auth-warning -a change-me-redis get visitor:total
```

### 7.3 Docker vs Pods vs Deployments vs Services

| Concept | What it is | In this project |
|---------|-----------|-----------------|
| **Container** | One isolated process tree built from an image | `visitor-counter:optimized` |
| **Pod** | Smallest Kubernetes unit; one or more containers sharing a network namespace. Disposable, gets a new name when recreated | `visitor-counter-xxxxx-yyyyy` |
| **Deployment** | Declares the desired state (replica count + Pod template) and reconciles reality to match → self-healing and rolling updates | `visitor-counter`, `redis` |
| **Service** | Stable virtual IP/DNS name in front of a changing set of Pods; load-balances to ready ones | `visitor-counter` (NodePort 30080), `redis` (ClusterIP 6379) |

## 8. Phase 4 — Self-healing

```powershell
# window 1
kubectl --context vc-primary get pods -l app=visitor-counter -w

# window 2
$pod = kubectl --context vc-primary get pods -l app=visitor-counter -o jsonpath='{.items[0].metadata.name}'
kubectl --context vc-primary delete pod $pod
```

Expected: the deleted Pod enters `Terminating`, and within seconds a **new Pod with
a new name** appears and becomes `1/1 Running` — you never restarted anything.
Meanwhile `http://localhost:8080` keeps answering because the Service only routes
to ready Pods, and the Pod name on the page changes.


## 9. Phase 5 — HPA autoscaling

`hpa.yaml` keeps 2–5 Flask Pods near **50% of the 100m CPU request**. The Metrics
Server must be running, otherwise usage shows `<unknown>`.

```powershell
kubectl --context vc-primary get apiservice v1beta1.metrics.k8s.io
kubectl --context vc-primary top pods
kubectl --context vc-primary get hpa
```

`TARGETS` must show a real percentage such as `3%/50%`, never `<unknown>/50%`.


```powershell
# window 1 - HPA
kubectl --context vc-primary get hpa visitor-counter-hpa -w

# window 2 - pods
kubectl --context vc-primary get pods -l app=visitor-counter -w

# window 3 - load from inside the cluster (recommended)
kubectl --context vc-primary apply -f loadtest.yaml

# or from Windows, measuring latency (stdlib only, no pip install)
python load_test.py --url http://localhost:8080/ --workers 30 --duration 180
```

Expected sequence in window 1: `TARGETS` rises above `50%`, `REPLICAS` grows from
`2` towards `5`. In window 2 new Pods appear and become Ready. Cross-check with
`kubectl top pods`: the per-Pod CPU is what caused the decision.

### 9.2 Stop the load and watch the scale-down

```powershell
kubectl --context vc-primary delete -f loadtest.yaml
kubectl --context vc-primary get hpa visitor-counter-hpa -w
```

Expected: utilization falls, the 60-second scale-down stabilization window
expires, and `REPLICAS` returns to `2` (the minimum). `kubectl describe hpa` shows
the scaling events with timestamps and reasons.

> If the HPA never scales up: the tunnel is usually the bottleneck, not the app.
> Use `loadtest.yaml` (traffic inside the cluster) or raise `--workers`. Verify
> with `kubectl top pods` that CPU actually rises.

## 10. Phase 6 — Hybrid cloud simulation and failover

Two independent clusters:

| Role | Profile / context | Meaning |
|------|-------------------|---------|
| Primary | `vc-primary` | simulated **private** cloud (active) |
| Secondary | `vc-secondary` | simulated **public** cloud (standby) |

They are two local Minikube clusters, not real clouds — same laptop, same Docker
Desktop, therefore the same failure domain. This is stated explicitly in the
report and in `failover/README.md`.

Create and deploy both (or simply run `.\scripts\setup.ps1`):

```powershell
minikube start -p vc-secondary --driver=docker --cpus=2 --memory=3584
minikube -p vc-secondary addons enable metrics-server
minikube -p vc-secondary image load visitor-counter:optimized
kubectl --context vc-secondary apply -f k8s.yaml
kubectl --context vc-secondary apply -f hpa.yaml

# make the secondary identify itself
kubectl --context vc-secondary -n default patch configmap visitor-counter-config --type merge -p '{"data":{"APP_LOCATION":"secondary-simulated-public-cloud"}}'
kubectl --context vc-secondary rollout restart deployment/visitor-counter
kubectl --context vc-secondary rollout status deployment/visitor-counter --timeout=240s
```

### Failover demonstration

```powershell
cd failover
.\failover.ps1 -Action start       # primary serves http://localhost:8080
.\failover.ps1 -Action status      # environment: primary-simulated-private-cloud

minikube -p vc-primary stop        # simulate primary failure

.\failover.ps1 -Action failover    # environment: secondary-simulated-public-cloud
# browser: http://localhost:8080 still works, footer shows the secondary

minikube -p vc-primary start       # bring the primary back
.\failover.ps1 -Action recover     # environment: primary-simulated-private-cloud again
```

Why this is real failover and not "switching contexts": the script owns the single
local endpoint `http://localhost:8080`. It kills the tunnel to the failed cluster
and opens one to the standby cluster on the **same port**, then verifies the
response and prints the environment that answered. The browser never changes its
URL.

**Data caveat (important for the viva):** each cluster has its **own** Redis and
PVC, with **no replication**. Availability survives the failover; the visit count
does **not** — after failover the page shows the secondary's own number, and after
recovery the primary's. Only availability is demonstrated, not data consistency.

**Screenshots 13–16** now: both clusters, failure simulation, successful failover.

## 11. Phase 7 — Cost optimization

Three techniques, each with a command whose output is the evidence. The full
pipeline runs with one command:

```powershell
.\scripts\measure.ps1
```

It builds both images, deploys `k8s-before.yaml` to sample the over-provisioned
baseline, restores `k8s.yaml` + `hpa.yaml`, samples again, and writes
`reports/cost_analysis.csv` with the real measured values and the arithmetic
improvements. The cluster is left in the normal state.

### Technique 1 — Docker image optimization

```powershell
docker build -f Dockerfile.baseline -t visitor-counter:baseline .
docker image inspect visitor-counter:baseline  --format "{{.Size}}"
docker image inspect visitor-counter:optimized --format "{{.Size}}"
```

| Change | Effect |
|--------|--------|
| `python:3.12-slim` instead of `python:3.12` | Removes compilers and build tooling from the image |
| `--no-cache-dir` / `PIP_NO_CACHE_DIR` | No pip cache layer stored |
| `requirements.txt` copied before `app.py` | Code edits reuse the dependency layer |
| Only 3 runtime packages | No test or dev dependencies |
| Non-root user + gunicorn | Security and production serving without extra size |

### Technique 2 — Kubernetes resource right-sizing

```powershell
kubectl --context vc-primary top pods -l app=visitor-counter
kubectl --context vc-primary get deployment visitor-counter -o jsonpath='{.spec.template.spec.containers[0].resources}'
```

`k8s-before.yaml` reserves 500m CPU / 512Mi per Pod. The measured idle usage is a
few millicores, so `k8s.yaml` uses 100m / 128Mi — still above real usage, never
below it. Reserved capacity that nobody uses is the local proxy for wasted money.

### Technique 3 — Replica and autoscaling optimization

| | Before (`k8s-before.yaml`) | After (`k8s.yaml` + `hpa.yaml`) |
|---|---|---|
| Idle replicas | 5 fixed | 2 (HPA minimum) |
| Peak replicas | 5 | 5 (HPA maximum) |
| CPU reserved at idle | 2500m | 200m |

```powershell
kubectl --context vc-primary get deployment visitor-counter -o jsonpath='{.status.replicas}'
kubectl --context vc-primary get hpa visitor-counter-hpa
```

The HPA removes idle cost without removing peak capacity.

> **Cost proxy statement.** No cloud account is used, so no monetary saving is
> claimed. Image size (MB), reserved millicores/mebibytes and replica counts are
> reported because those are the inputs real billing is derived from. Do not write
> a rupee/dollar figure into the report that was never billed.



