# Deploying a Visitor Counter Web Application on Docker and Kubernetes with HPA Autoscaling, Hybrid Cloud Failover and Cost Optimization

## A Cloud Computing Project Report

# 1. Abstract

This project implements a Visitor Counter web application and deploys it through
three progressively more realistic environments: a local Python process, a
Docker Compose stack, and a Kubernetes cluster created with Minikube. The
application is written in Python with the Flask framework and stores its visit
count in Redis. The count is incremented atomically on each request, and the
page is served even when Redis is unavailable, which demonstrates graceful
degradation. On Docker Compose the two containers communicate over a private
bridge network and Redis keeps its data in a named volume, so the count survives
restarts. On Kubernetes the same image runs as a Deployment with readiness and
liveness probes, a ConfigMap for non-sensitive configuration, a Secret for the
Redis password, a PersistentVolumeClaim for Redis data and a NodePort Service for
external access. A Horizontal Pod Autoscaler driven by the Metrics Server keeps
the application between two and five Pods with a CPU target of 50 percent. The
project also simulates a hybrid cloud by running two independent Minikube
clusters, one labelled as a simulated private cloud and one as a simulated public
cloud, and implements a failover script that actually moves the active
application endpoint from the primary cluster to the secondary cluster and back
again. Finally, three cost optimizations are applied and measured: Docker image
optimization, Kubernetes resource right-sizing, and replica/autoscaling
optimization. Because the project runs entirely on one laptop, cost is analysed
through locally measurable proxies such as image size, reserved CPU and memory,
and replica counts, rather than claimed monetary savings.

**Keywords:** cloud computing, containers, Docker, Kubernetes, Minikube, Flask,
Redis, autoscaling, Horizontal Pod Autoscaler, hybrid cloud, failover, cost
optimization.

# 2. Introduction

Cloud computing platforms allow an application to be packaged once and run
anywhere, to be replicated automatically when demand increases and to be
recovered automatically when a component fails. These properties are usually
learned through paid public cloud accounts. This project instead builds a
complete, reproducible environment on a single Windows 11 laptop using Docker
Desktop and Minikube, which are free and require no cloud subscription.


The result is a project that a student can run, explain and demonstrate: the
same image runs under Docker Compose and under Kubernetes, the autoscaler reacts
to real measured CPU usage, two clusters simulate a hybrid cloud, a script
performs failover by changing the endpoint that the browser talks to, and three
optimizations are quantified with commands whose output is recorded in
`reports/cost_analysis.csv`.

# 3. Problem Statement

Deploying even a small web application properly raises several engineering
problems:

1. The application must run identically on a developer laptop and inside a
   cluster, without editing code between environments.
2. Its data store must persist across container restarts, which a container's
   own filesystem does not guarantee.
3. The deployment must survive Pod failures without manual intervention.
4. Capacity must follow demand: a fixed number of replicas wastes resources at
   idle and cannot absorb traffic peaks.
5. A single cluster is a single point of failure, so a second environment and a
   switch-over mechanism are needed to keep the service available.
6. Every reserved CPU or memory unit and every always-on replica has a cost, so
   the resource configuration must be justified by measurements rather than
   guessed.

The problem addressed by this project is to satisfy all six requirements with
free, local tooling, and to verify each of them experimentally rather than
claiming them.

# 4. Objectives

The objectives of the project are:

1. To develop a Flask application whose visit counter is stored in Redis, with a
   health endpoint and graceful handling of Redis failures.
2. To containerize the application with an efficient Dockerfile and orchestrate
   it with Docker Compose together with Redis and persistent storage.
3. To deploy the application to Kubernetes (Minikube) with Deployments,
   Services, ConfigMap, Secret, PersistentVolumeClaim, resource requests and
   limits, and health probes.
4. To enable the Metrics Server and configure a Horizontal Pod Autoscaler with a
   50 percent CPU target, two minimum replicas and five maximum replicas, and to
   verify scale-up and scale-down with real metrics.
5. To simulate a hybrid cloud using two independent Minikube clusters and to
   implement a working failover and recovery mechanism.
6. To apply and measure at least three cost optimization techniques and record
   the before-and-after values in a machine-readable CSV file.
7. To document the work in an academic report and publish the source code in a
   public GitHub repository.

# 5. Technologies Used

| Technology | Version used | Role in the project |
|------------|--------------|---------------------|
| Python | 3.11+ locally, 3.12 in the image | Application language |
| Flask | 3.0.3 | HTTP routing and page rendering |
| redis-py | 5.0.8 | Redis client with atomic `INCR` |
| gunicorn | 22.0.0 | Production WSGI server inside the image |
| Redis | 7 (alpine) | Visit counter data store |
| Docker Desktop | current stable | Container runtime with the Docker driver for Minikube |
| Docker Compose | v2 (`docker compose`) | Local multi-container orchestration |
| Minikube | current stable | Single-node Kubernetes clusters on the laptop |
| kubectl | current stable | Kubernetes command line client |
| Metrics Server | Minikube addon | Supplies CPU and memory metrics to the HPA |
| Horizontal Pod Autoscaler | `autoscaling/v2` | CPU-based autoscaling |
| PowerShell | 5.1 or 7.x | Automation scripts on Windows 11 |

# 6. System Requirements

**Hardware (minimum, for two clusters):** a quad-core CPU, 16 GB RAM and 25 GB
free disk space. Docker Desktop should be configured with at least 6 GB of memory
and 4 CPUs.

**Software:** Windows 11, Docker Desktop (with the Docker engine running),
Minikube, kubectl, Python 3.11 or newer, and Visual Studio Code. All tooling is
free and no cloud account is required.

**Browser:** any modern browser to open `http://localhost:8080`.

# 7. System Architecture

The architecture has four layers.

**Layer 1 - Presentation.** The user's browser requests the homepage from
`http://localhost:8080`.

**Layer 2 - Application.** A Flask application served by gunicorn receives the
request, increments a counter key in Redis with the atomic `INCR` command and
renders the new total together with the environment name and Pod name. The
environment and Pod are displayed on purpose: they make autoscaling and failover
visible in the browser.

**Layer 3 - Data.** Redis stores the counter. In Docker Compose it writes an
append-only file to a named volume; in Kubernetes it writes to a
PersistentVolumeClaim. A password from a Secret protects the instance.

**Layer 4 - Orchestration and operations.** Docker Compose provides a private
bridge network and health checks. Kubernetes provides the Deployment (desired
state and self-healing), the Service (stable virtual IP and NodePort), the HPA
(replica control loop driven by the Metrics Server) and two separate clusters for
the hybrid cloud simulation, connected operationally by the failover script.

The diagram in `reports/architecture.png` shows the request path, the control
path (autoscaling, failover) and the limitation that Redis data is not replicated
between the clusters.

[INSERT: reports/architecture.png - copy the generated diagram into the report]

# 8. Application Implementation

The application is a single file, `app.py`, built with the Flask application
factory pattern. Configuration is read exclusively from environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `REDIS_HOST` | `localhost` | Host name of Redis (`redis` in Docker and Kubernetes) |
| `REDIS_PORT` | `6379` | Redis port |
| `REDIS_DB` | `0` | Redis database index |
| `REDIS_PASSWORD` | empty | Password supplied by the Secret or the Compose file |
| `VISIT_COUNTER_KEY` | `visitor:total` | Name of the counter key |
| `APP_LOCATION` | `local-laptop` | Environment label displayed on the page |
| `POD_NAME` | hostname | Pod name injected by the Kubernetes downward API |
| `APP_PORT` | `5000` | Port of the Flask process |

Three endpoints are exposed:

* `GET /` increments the counter and renders the homepage.
* `GET /health` pings Redis, returns the current count and answers HTTP 200 when
  Redis is reachable or HTTP 503 when it is not. Kubernetes uses it as the
  readiness probe.
* `GET /healthz` only proves that the process is alive and never touches Redis.
  Kubernetes uses it as the liveness probe.

Separating the two probes matters: a Redis outage should remove a Pod from the
Service (readiness) but should not restart a perfectly healthy Flask process
(liveness).

Redis failures are handled gracefully. The client uses short socket timeouts, and
the homepage catches `redis.RedisError`: instead of an error page the user sees
the normal layout with a clear warning that the counter is temporarily
unavailable, while the failure is written to the log. Caching is disabled with a
`Cache-Control: no-store` response header, otherwise a browser refresh could show
a stale number and load tests would not reach the application.

[INSERT: Screenshot 1 - `python app.py` running locally with the page open in the browser]

# 9. Docker Containerization

The application image is built from `python:3.12-slim`. The dependency list is
copied before the source code so that editing `app.py` does not invalidate the
dependency layer, pip runs with `--no-cache-dir`, and only the three packages that
are needed at runtime are installed. The container runs as the non-root user
`appuser` (UID 10001), exposes port 5000, serves the application with gunicorn
(two workers, four threads) and declares a `HEALTHCHECK` against `/healthz`.

`docker-compose.yml` defines two services on the private network
`visitor-counter-net`:

* `flask` builds the image, publishes `8080:5000`, receives its configuration as
  environment variables and waits for Redis to become healthy
  (`depends_on: condition: service_healthy`).
* `redis` runs `redis:7-alpine` with append-only persistence enabled and a
  password, mounts the named volume `visitor-counter-redis-data` on `/data` and
  exposes a health check that runs `redis-cli ping`.

Because Redis writes to a named volume, `docker compose down` followed by
`docker compose up -d` keeps the visit count: the deployment is stateless while
the data is persistent, which is the intended separation.

[INSERT: Screenshot 2 - `docker build` completed successfully]
[INSERT: Screenshot 3 - `docker compose ps` showing both containers healthy]
[INSERT: Screenshot 4 - the application served from Docker Compose]

# 10. Kubernetes Deployment

`k8s.yaml` contains the complete application stack:

1. **Secret** `visitor-counter-secret` - the Redis password.
2. **ConfigMap** `visitor-counter-config` - Redis host and port, counter key,
   application port, environment label and log level.
3. **PersistentVolumeClaim** `redis-storage` - 1 GiB, using the default Minikube
   StorageClass.
4. **Deployment** `redis` - one Pod using the `Recreate` strategy, because a
   ReadWriteOnce volume cannot be attached to two Pods at the same time.
5. **Service** `redis` - ClusterIP on port 6379, reached by the DNS name `redis`.
6. **Deployment** `visitor-counter` - two Flask Pods, a rolling update strategy
   (`maxUnavailable: 0`), CPU request 100m and limit 500m, memory request 128Mi
   and limit 256Mi, a readiness probe on `/health` and a liveness probe on
   `/healthz`, running as non-root.
7. **Service** `visitor-counter` - NodePort 30080 forwarding to container port
   5000.

Resource requests are not decoration: the HPA compares measured usage with the
CPU *request*, so 100m and a 50 percent target mean the HPA tries to keep each Pod
near 50m of CPU. Requests also decide whether a Pod can be scheduled at all.

Pods and Deployments and Services are different things, and the project
demonstrates the difference:

* A **container** is one packaged process tree; it knows nothing about clusters.
* A **Pod** is the smallest Kubernetes unit and wraps one or more containers with
  a shared network namespace; it is replaceable and gets a new name when
  recreated.
* A **Deployment** declares the desired state ("two replicas of this Pod
  template") and runs a reconciliation loop that creates and replaces Pods to
  match it - that is the self-healing mechanism.
* A **Service** gives a stable virtual IP and DNS name to a changing set of Pods
  and load-balances traffic across the ready ones, so clients never need Pod IPs.

Access from Windows is provided with `minikube service visitor-counter --url` or,
more reliably, with `kubectl port-forward svc/visitor-counter 8080:80`, which the
failover script automates.

[INSERT: Screenshot 5 - `minikube status`]
[INSERT: Screenshot 6 - `kubectl get pods` with all Pods Running and Ready]
[INSERT: Screenshot 7 - `kubectl get deployments,services`]
[INSERT: Screenshot 8 - the application served through Minikube]

# 11. Self-Healing Demonstration

Kubernetes compares the observed state with the declared state. When a Pod that
belongs to the `visitor-counter` Deployment is deleted, the Deployment controller
notices that fewer replicas exist than declared and creates a new Pod
immediately. The new Pod is scheduled, pulls or reuses the image, passes its
readiness probe and then receives traffic.

The demonstration is performed with:

```powershell
kubectl get pods -l app=visitor-counter -w
# in a second window
$pod = kubectl get pods -l app=visitor-counter -o jsonpath='{.items[0].metadata.name}'
kubectl delete pod $pod
```

The first window shows the deleted Pod terminating and a replacement appearing
with a different name within seconds, while `http://localhost:8080` continues to
answer because the Service only routes to ready Pods. The Pod name displayed on
the page changes accordingly, which is visible proof that a different Pod served
the request. No manual restart command is issued at any point.

[INSERT: Screenshot 9 - deleted Pod and the automatically created replacement]

# 12. HPA Autoscaling Implementation

The Metrics Server addon is enabled with
`minikube addons enable metrics-server`. It periodically collects CPU and memory
usage from the kubelets and exposes it through the resource metrics API, which is
what `kubectl top` and the HPA read.

`hpa.yaml` defines an `autoscaling/v2` HPA that targets the `visitor-counter`
Deployment with:

* `minReplicas: 2` - high availability at idle without over-reserving capacity,
* `maxReplicas: 5` - the cost ceiling for a traffic peak,
* a CPU utilization target of 50 percent of the 100m request,
* a fast scale-up behaviour (up to two Pods or 100 percent every 30 seconds) and
  a slow scale-down behaviour (60-second stabilization window, one Pod every
  30 seconds) to avoid flapping.

The HPA computes the desired replica count from the ratio between current and
target utilization. If the average CPU across the Pods is 150 percent of the
request, the HPA roughly triples the replica count, limited by `maxReplicas` and
by the configured policies. Note that utilization is always relative to the
request, which is why an unrealistic request makes the HPA behave badly: too
large a request keeps utilization low and prevents scaling, too small a request
causes permanent maximum scale-out.

Load is generated with `python load_test.py`, which uses only the Python standard
library so it runs on a fresh Windows machine without installing anything. For
autoscaling measurements the in-cluster generator `loadtest.yaml` is preferable,
because a single `kubectl port-forward` tunnel would bottleneck the traffic before
the Pods become busy.

```powershell
# window 1
kubectl get hpa visitor-counter-hpa -w
# window 2
kubectl get pods -l app=visitor-counter -w
# window 3
kubectl apply -f loadtest.yaml
# ... after the scaling is captured, stop the load
kubectl delete -f loadtest.yaml
```

Scale-up is confirmed by three independent observations: `kubectl get hpa` shows
the current CPU percentage rise above the 50 percent target and the replicas
column increase; `kubectl get pods` shows new Pods becoming Ready; and
`kubectl top pods` shows the per-Pod CPU that caused the decision. After the
generator is deleted, utilization drops, the stabilization window expires and the
replica count returns to two. Self-healing and autoscaling are different
mechanisms: self-healing restores the declared replica count, autoscaling changes
that declared count.

[INSERT: Screenshot 10 - `kubectl get hpa` and `kubectl describe hpa`]
[INSERT: Screenshot 11 - replica count rising above 2 during the load test]
[INSERT: Screenshot 12 - replica count back at 2 after the load stopped]

# 13. Hybrid Cloud Simulation

A hybrid cloud combines a private environment with a public one. A single laptop
cannot provide a real private datacentre or a real public cloud, so the project
builds an explicit simulation with two independent Minikube clusters:

| Item | Cluster 1 | Cluster 2 |
|------|-----------|-----------|
| Minikube profile | `vc-primary` | `vc-secondary` |
| Kubernetes context | `vc-primary` | `vc-secondary` |
| Simulated role | Private cloud (active) | Public cloud (standby) |
| Resources | 4 CPU / 6 GB | 2 CPU / 3.5 GB |
| `APP_LOCATION` | `primary-simulated-private-cloud` | `secondary-simulated-public-cloud` |

Each cluster has its own control plane, its own network, its own Redis
Deployment, its own PersistentVolumeClaim and its own copy of the application
image. They share nothing except the laptop's hardware and the failover script.
This is stated clearly because two local clusters are not two clouds: they share a
failure domain (the laptop) and a resource pool (Docker Desktop).

The distinction between the environments is visible at runtime: the ConfigMap of
the secondary cluster stores a different `APP_LOCATION`, so both the page footer
and the `/health` JSON report which simulated environment answered the request.

# 14. Failover Demonstration

Failover requires an endpoint that can be moved. Minikube Services are reached
from Windows through a `kubectl port-forward` tunnel, so the project defines the
active endpoint as the fixed address `http://localhost:8080`, which only one
tunnel can own. `failover/failover.ps1` implements four operations:

* `-Action start` opens the tunnel to the primary cluster;
* `-Action status` prints the active context and the `/health` payload;
* `-Action failover` probes the endpoint, terminates the tunnel to the failed
  cluster and opens a tunnel to the standby cluster on the same local port, then
  verifies the response;
* `-Action recover` first verifies that the primary is healthy again on a scratch
  port, and only then switches the endpoint back, so a premature recovery attempt
  cannot take the service down;
* `-Action watch` repeats the probe every few seconds and fails over
  automatically after a configurable number of consecutive failures.

The procedure is:

```powershell
.\failover\failover.ps1 -Action start      # primary serves localhost:8080
minikube -p vc-primary stop                # simulate primary failure
.\failover\failover.ps1 -Action failover   # secondary serves localhost:8080
minikube -p vc-primary start               # restart the primary
.\failover\failover.ps1 -Action recover    # primary serves localhost:8080 again
```

# 15. Cost Optimization Techniques

Three optimizations are applied. Each one has a command whose output is the
evidence, and the values are written to `reports/cost_analysis.csv` by
`scripts/measure.ps1`.

**Technique 1 - Docker image optimization.** The baseline image
(`Dockerfile.baseline`) uses the full `python:3.12` base, keeps the pip cache,
runs as root and starts the Flask development server. The optimized image
(`Dockerfile`) uses `python:3.12-slim`, disables the pip cache, copies
`requirements.txt` first to exploit layer caching, installs only three packages,
runs as a non-root user and serves with gunicorn. A smaller image means faster
pulls, faster Pod start-up (which matters when the HPA adds Pods) and less
registry and disk usage. Both sizes are read with
`docker image inspect <image> --format "{{.Size}}"`.

**Technique 2 - Kubernetes resource right-sizing.** The baseline
(`k8s-before.yaml`) reserves 500m CPU and 512Mi memory per Pod, which was a guess
rather than a measurement. Idle usage is sampled with `kubectl top pods -l
app=visitor-counter`, and the requests are set to 100m CPU and 128Mi memory, still
with headroom above the observed usage. Reserved resources are unavailable to
other workloads, so an oversized request wastes cluster capacity - the local
proxy for cloud cost.

**Technique 3 - Replica and autoscaling optimization.** The baseline runs five
fixed Pods permanently. The optimized configuration runs two Pods at idle and
lets the HPA add up to five only while the CPU target is exceeded. Idle capacity
drops while peak capacity is preserved, which is measured by comparing
`kubectl get deployment visitor-counter -o jsonpath='{.status.replicas}'` before
and after, together with the HPA configuration.

An additional small optimization is part of the design: Redis runs with
`redis:7-alpine` and only the append-only file, with a 200m CPU limit, so the data
store does not reserve capacity it never uses.

**Cost proxy statement.** No public cloud is used, therefore no monetary figure is
claimed. The analysis uses locally measurable quantities - image size in
megabytes, reserved millicores, reserved mebibytes and replica counts - as a cost
proxy. In a real cloud these are the inputs that billing is calculated from, but
the project does not convert them into currency.

# 16. Before-and-After Cost Analysis

The values below are produced by `scripts/measure.ps1` on the student's own
machine and stored in `reports/cost_analysis.csv`. The table must be filled from
that CSV, not from expectation:

| Optimization | Metric | Before | After | Improvement | Measurement method |
|--------------|--------|--------|-------|-------------|--------------------|
| Docker image | Image size | [INSERT measured MB] | [INSERT measured MB] | [INSERT %] | `docker image inspect <image> --format "{{.Size}}"` |
| Resource right-sizing | CPU request per Pod | 500m (k8s-before.yaml) | 100m (k8s.yaml) | -80 % | `kubectl get deployment ... resources.requests.cpu` |
| Resource right-sizing | Memory request per Pod | 512Mi | 128Mi | -75 % | `kubectl get deployment ... resources.requests.memory` |
| Resource right-sizing | Idle CPU per Pod (measured) | [INSERT m] | [INSERT m] | usage unchanged; reservation reduced | `kubectl top pods -l app=visitor-counter` |
| Replicas | Idle Flask replicas | 5 fixed | 2 (HPA minimum) | -60 % | `kubectl get deployment ... {.status.replicas}` |
| Replicas | Peak capacity | 5 | 2-5 (HPA) | capacity preserved | `kubectl get hpa` |

Reading of the table: reducing the CPU request by 80 percent does not change the
measured usage of the application - it changes how much capacity is *reserved and
paid for*. The saving that matters is the product of the request and the number
of idle replicas, which the CSV records as a separate row (2500m reserved at
baseline versus 200m after optimization). All percentage values are arithmetic
on measured or configured inputs and are recalculated by the script, so they
cannot drift from the data.

# 17. Results and Discussion

The project achieved its objectives in the following sense:

1. One image runs unmodified under Docker Compose and under Kubernetes, because
   all environment-specific values are injected as environment variables.
2. Redis data survives container restarts (named volume) and Pod restarts
   (PersistentVolumeClaim).
3. Deleting a Pod leads to an automatic replacement, demonstrating the
   Deployment reconciliation loop.
4. The HPA scales between two and five Pods based on measured CPU relative to the
   100m request, and returns to two Pods when load stops.
5. Two independent clusters and a script-based endpoint switch demonstrate
   availability failover, with the visited environment visible on the page.
6. Three optimizations are quantified with reproducible commands and recorded in
   `reports/cost_analysis.csv`.

Discussion points worth noting in the viva:

* The readiness probe deliberately fails when Redis is unreachable. This makes
  the Service stop sending traffic to Pods that cannot count visits, which is
  correct for this application but would be wrong for an application that can
  serve useful content without its database.
* Autoscaling latency is dominated by Pod start-up: a smaller image and readiness
  probes that pass early make scale-out faster, which is why Techniques 1 and 3
  reinforce each other.
* The single-endpoint failover design works for a demonstration but is not a
  global load balancer; a real solution would use DNS or anycast with health
  checks.

# 18. Limitations

1. Two Minikube clusters on one laptop are a *simulation* of a hybrid cloud. They
   share the same physical host, so a laptop failure or a Docker Desktop stop
   takes both environments down.
2. Redis is not replicated between clusters. After failover the counter shows the
   secondary's own value; the global total is not preserved. Only availability is
   demonstrated, not data consistency.
3. Failover is performed by a PowerShell script that switches a local tunnel, not
   by a managed load balancer with health checks.
4. The service is reachable only at `http://localhost:8080` on the same machine;
   there is no public DNS name and no TLS.
5. Cost analysis uses local resource measurements as a proxy. No monetary savings
   are claimed because no billing exists without a cloud account.
6. Both clusters together need roughly 10 GB of RAM available to Docker Desktop,
   so the project is demonstrated with a small number of replicas.
7. The Redis password lives in a Secret inside the repository for demonstration
   purposes. In a real deployment it would be generated and injected by a secret
   manager and never committed.

# 19. Future Scope

1. Replace independent Redis instances with a shared or replicated data store
   (Redis replication with Sentinel, or a managed Redis service) so the counter is
   consistent across clusters.
2. Replace the script-based switch with DNS-based failover, for example two
   ingresses behind a local DNS name with health-checked records.
3. Add TLS and an Ingress controller so the application is served over HTTPS on a
   hostname rather than a port-forward.
4. Store images in a local registry and add a CI pipeline that builds, tests and
   scans the image.
5. Extend the HPA with memory metrics and add a PodDisruptionBudget and
   anti-affinity rules.
6. Move the counter to Redis `HINCRBY` per day and expose a small analytics
   endpoint, which would better justify the data layer.
7. Add monitoring with Prometheus and Grafana, and alerting on error rate and
   restart counts.

# 20. Conclusion

The project delivers a complete, working cloud computing exercise on free local
tooling: a Flask and Redis visitor counter, containerized with an optimized
image, orchestrated with Docker Compose and Kubernetes, autoscaled with a
Metrics-Server-driven Horizontal Pod Autoscaler, protected by readiness and
liveness probes, and simulated across two clusters with a failover script that
demonstrably changes which environment serves the browser.

Equally important is what the project documents honestly: two local clusters are
not two clouds, an endpoint switch is not a global load balancer, and independent
Redis instances do not provide data consistency. The cost analysis reports
measurements that the reader can reproduce with the included scripts, expressed in
locally observable units instead of invented monetary figures.

# 21. References

1. Python Software Foundation, *Python 3 documentation*, https://docs.python.org/3/
2. Pallets Projects, *Flask documentation*, https://flask.palletsprojects.com/
3. Redis Ltd., *Redis documentation - INCR, AOF persistence*, https://redis.io/docs/
4. Docker Inc., *Dockerfile reference* and *Compose specification*, https://docs.docker.com/
5. The Kubernetes Authors, *Kubernetes documentation - Deployments, Services, Probes, Resource management*, https://kubernetes.io/docs/
6. The Kubernetes Authors, *Horizontal Pod Autoscaling*, https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
7. The Kubernetes Authors, *Configure a Pod to use a PersistentVolume for storage*, https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/
8. Minikube project, *Minikube documentation - drivers, addons, image load*, https://minikube.sigs.k8s.io/docs/
9. Microsoft, *PowerShell documentation*, https://learn.microsoft.com/powershell/
