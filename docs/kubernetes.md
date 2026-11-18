# Kubernetes (kind)

The app runs on a local [kind](https://kind.sigs.k8s.io/) cluster with one control plane and two
workers. The manifests are plain YAML composed with Kustomize under [`k8s/`](../k8s), and the
Contour ingress controller and metrics-server are installed from pinned upstream releases.

## Run it

Prerequisites: Docker, **kind ≥ v0.33.0** (its node image is pinned to Kubernetes v1.36.4 in
[`k8s/kind-cluster.yaml`](../k8s/kind-cluster.yaml)), and kubectl 1.36.

```bash
bash scripts/kind-up.sh          # cluster + add-ons + build/load image + secret + deploy (idempotent)
bash scripts/k8s-verify.sh       # routing and security controls, 13 checks
bash scripts/k8s-rollout-demo.sh # zero-downtime rolling update + kubectl rollout undo
bash scripts/k8s-hpa-demo.sh     # HPA scale-out under load
kind delete cluster --name devops-task
```

| Access | |
|--------|--|
| Ingress | `curl http://devops-task.localtest.me:8088/`, or `curl -H 'Host: devops-task.localtest.me' http://127.0.0.1:8088/` (`*.localtest.me` resolves to 127.0.0.1 in public DNS, so there is no `/etc/hosts` edit). Port 8088 on 127.0.0.1 is mapped to the Envoy hostPort on a worker. |
| Port-forward alternative | `kubectl -n devops-task port-forward svc/devops-task-api 8081:80`, then `curl localhost:8081/` |

> **Laptop resources.** The Compose observability stack and a 3-node kind cluster together did
> not fit in Docker Desktop's 3.7 GB VM (load average > 50, API server timeouts). Stop the Compose
> stack first with `docker compose stop` and start it again later with `docker compose start`.

## What gets deployed

```
k8s/
├── kind-cluster.yaml          1 control plane + 2 workers, node image pinned by digest, host 127.0.0.1:8088 -> ingress
├── addons/contour/            ingress controller (Envoy), pinned upstream release
├── addons/metrics-server/     resource metrics for the HPA (+ --kubelet-insecure-tls, kind only)
├── base/                      environment-independent manifests
│   ├── namespace.yaml         Pod Security Admission: enforce "restricted"
│   ├── serviceaccount.yaml    own identity, no API token mounted
│   ├── deployment.yaml        2 replicas, rolling update, probes, resources, securityContext
│   ├── service.yaml           ClusterIP
│   ├── ingress.yaml           Contour, transport-level retries
│   ├── hpa.yaml               CPU, 2-5 replicas, fast up / slow down
│   ├── pdb.yaml               minAvailable 1
│   ├── networkpolicy.yaml     default deny + allow from the ingress controller only
│   └── kustomization.yaml     namespace, labels, ConfigMap generator
└── overlays/kind/             image tag, APP_ENV, Secret generator (from a git-ignored file)
```

## Design decisions

**Probes.**
- *startupProbe* on `/health` (2 s × 15) gives the app up to 30 s to start before liveness can
  kill it.
- *readinessProbe* (every 5 s, 2 failures) takes a pod out of the Service quickly.
- *livenessProbe* (every 10 s, 3 failures) restarts a stuck pod, and is deliberately more tolerant
  than readiness. A slow pod should first stop receiving traffic, not be restarted straight away.

**Resources.** Requests are `100m` CPU / `64Mi` memory, and limits are `500m` / `256Mi`. Requests
are what the scheduler reserves and what the HPA percentage is measured against. Measured idle usage
is ~4% of the CPU request and ~40 MiB. The memory limit matches the Compose setup. CPU over the limit
is throttled; memory over the limit is OOM-killed, which the observability alerts cover.

**Zero-downtime rollouts.**
- `maxUnavailable: 0, maxSurge: 1`: a new pod is added and must be Ready (plus `minReadySeconds: 5`)
  before an old one is removed.
- `preStop: sleep 10s` keeps a terminating pod serving while Contour/Envoy remove it from their
  endpoints, before SIGTERM. Uvicorn then drains in-flight requests (up to 20 s), all within the
  30 s grace period.
- `timeout_keep_alive=65` in the app and **retries of transport-level failures** at the ingress
  (see below for why both were needed).
- `revisionHistoryLimit: 5` keeps enough ReplicaSets for `kubectl rollout undo`.

**Availability.**
- HPA min 2 means no single point of failure.
- `topologySpreadConstraints` spreads replicas over nodes, so the two pods land on different workers.
- The PodDisruptionBudget (`minAvailable: 1`) keeps a node drain or cluster upgrade from taking both
  replicas at once.
- HPA `behavior`: scale up by 2 pods per 30 s with no delay; scale down by 1 pod per minute after a
  5-minute stabilization window, so bursty traffic doesn't make it flap.

**Security.**
- The namespace enforces **Pod Security "restricted"**, so the API server itself rejects anything
  weaker.
- Pod and container `securityContext`: non-root UID 10001, `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault` seccomp.
- `/tmp` is a memory-backed `emptyDir` with a size limit.
- `automountServiceAccountToken: false`: the app doesn't call the Kubernetes API, so it holds no
  credentials for it.
- **NetworkPolicy:** default deny for ingress and egress in the namespace. Only Contour's Envoy pods
  (and a future `monitoring` namespace, for scraping) may connect to port 8080. The app makes no
  outbound calls, so no egress is allowed, not even DNS.

**Config and secrets.**
- Configuration is a `configMapGenerator` (`LOG_LEVEL`, `APP_ENV`, `PORT`). Its name carries a
  content hash, so a config change rolls the pods automatically instead of leaving them on stale
  values. `APP_VERSION` is baked into the image.
- The Secret comes from a `secretGenerator` reading `k8s/overlays/kind/secrets.env`, which is
  **git-ignored**. `kind-up.sh` creates it with a random value, and only `secrets.env.example` is
  committed.
- In the pod it is mounted as a read-only **file** under `/run/secrets/app` (mode 0440, group via
  `fsGroup`), not an environment variable. Env vars leak into child processes, crash dumps and
  `kubectl describe`.
- The app has no real secret today, so `APP_SECRET_KEY` demonstrates the delivery path a database
  password or API key would use. Production replaces the generator; see the EKS section.

**Ingress controller: Contour.** The usual choice, ingress-nginx, was retired upstream in March 2026,
so a new setup shouldn't start on it. Contour (CNCF, Envoy-based) installs from one pinned manifest
without Helm, supports both `Ingress` and Gateway API, and its Envoy DaemonSet binds hostPort 80,
which kind maps to the host.

## Verification: are the controls actually enforced?

[`scripts/k8s-verify.sh`](../scripts/k8s-verify.sh) checks behaviour, not just YAML. For example,
the NetworkPolicy test has a positive control, so "blocked" can't simply mean "the network is broken":

```
# Routing
PASS  GET / through the Ingress returns the app's JSON
PASS  GET /health through the Ingress returns 200
PASS  at least 2 replicas are available
# Container hardening (inside devops-task-api-65b7c79568-9j5wq)
PASS  runs as UID 10001, not root
PASS  root filesystem is read-only
PASS  /tmp is writable (memory-backed emptyDir)
PASS  secret is a readable file under /run/secrets/app
PASS  secret is not exposed as an environment variable
PASS  no Kubernetes API token is mounted
# NetworkPolicy (default deny; only the ingress controller may connect)
PASS  control: a pod in 'default' can reach Envoy (so the network works)
PASS  a pod in 'default' cannot reach the API service directly
# Pod Security admission (namespace enforces 'restricted')
PASS  a root pod without a securityContext is rejected by the API server
# Autoscaling
PASS  HPA receives CPU metrics from metrics-server

passed: 13, failed: 0
```

## Zero-downtime rolling update and rollback

[`scripts/k8s-rollout-demo.sh`](../scripts/k8s-rollout-demo.sh) sends a request through the
Ingress every ~50 ms the whole time. It rolls the Deployment from `0.1.0` to `0.2.0`, then back
with `kubectl rollout undo`, and fails if any request is not answered with 200 within 5 s.

```
Current image: devops-task-api:0.1.0   ->   new image: devops-task-api:0.2.0

### 1. Rolling update to 0.2.0 (traffic flowing the whole time)

$ kubectl -n devops-task set image deployment/devops-task-api api=devops-task-api:0.2.0
deployment.apps/devops-task-api image updated

$ kubectl -n devops-task rollout status deployment/devops-task-api --timeout=180s
deployment "devops-task-api" successfully rolled out
  Responses during the update:
        62 x HTTP 200  version 0.1.0
        38 x HTTP 200  version 0.2.0
    slowest response: 2.160s

$ kubectl -n devops-task rollout history deployment/devops-task-api
REVISION  CHANGE-CAUSE
1         running devops-task-api:0.1.0
2         set image devops-task-api:0.2.0

### 2. Roll back with kubectl rollout undo

$ kubectl -n devops-task rollout undo deployment/devops-task-api
deployment.apps/devops-task-api rolled back

$ kubectl -n devops-task rollout status deployment/devops-task-api --timeout=180s
deployment "devops-task-api" successfully rolled out
  Responses during the rollback:
        40 x HTTP 200  version 0.1.0
        80 x HTTP 200  version 0.2.0
    slowest response: 2.040s

$ kubectl -n devops-task rollout history deployment/devops-task-api
REVISION  CHANGE-CAUSE
2         set image devops-task-api:0.2.0
3         rollout undo to devops-task-api:0.1.0

$ kubectl -n devops-task get pods -o wide
NAME                               READY   STATUS        AGE     NODE
devops-task-api-65b7c79568-9j5wq   1/1     Running       78s     devops-task-worker2
devops-task-api-65b7c79568-gjkmw   1/1     Running       44s     devops-task-worker
devops-task-api-6fb78488b5-xpjxw   1/1     Terminating   2m18s   devops-task-worker

### Result: 225 requests through the Ingress, 0 not answered with 200 (slowest 2.160s)
```

Both versions answered side by side while pods were swapped, and the old revision came back with
`rollout undo` (revision 1 becomes revision 3), with no failed request. `rollout undo` warns that
it doesn't update `last-applied-configuration`. That is the reason it is the emergency lever, while
the normal rollback is reverting the image tag in the overlay (git) and applying it.

### How it got to zero

The first runs were not clean, and the fixes are worth more than the green result:

1. **Some responses took over 2 s and timed out**, with Envoy flag `DC` (the client gave up). The
   cause was not Kubernetes: Docker Desktop's VM was saturated (load > 20 while images were
   side-loaded and the Compose stack was still running). The probe's client timeout is now 5 s, and
   the slowest response is reported instead of hidden. All "slow" requests in the Envoy log still
   completed with 200.
2. **One real `503` with Envoy flag `UC`** (upstream connection termination). Envoy reused a pooled
   keep-alive connection that the old pod closed at the same moment. Two root causes were fixed:
   uvicorn closed idle connections after **5 s** while Envoy keeps them far longer (now
   `timeout_keep_alive=65`, above Envoy's and AWS ALB's 60 s idle timeouts, a classic 502/503
   source behind any load balancer), and `preStop` went from 5 s to **10 s**, because endpoint
   removal took longer than 5 s on the loaded node.
3. **The ingress now retries transport-level failures** (`reset, connect-failure, refused-stream`,
   2 retries, 2 s per try). Real HTTP 500s are *not* retried, which would double the load on a
   failing endpoint. Measured over three consecutive runs (674 requests): **0 failures**, while
   Envoy's own counters show `upstream_rq_retry_success = 4`. Fixes 1 and 2 removed most resets;
   the retry absorbed the remaining four. Retrying is safe here because the API is read-only. A
   service with non-idempotent POSTs would need idempotency keys before retrying resets.

## Autoscaling

[`scripts/k8s-hpa-demo.sh`](../scripts/k8s-hpa-demo.sh) drives load with
[fortio](https://fortio.org) through the Ingress (so the NetworkPolicy still applies) and watches the HPA:

```
Before load:
  cpu 4% of request (target 70%)   replicas 2 (desired 2)
Load started (fortio, 16 connections, up to 400 req/s through the Ingress)
  15s  cpu 14% of request (target 70%)   replicas 2 (desired 2)
  30s  cpu 326% of request (target 70%)   replicas 2 (desired 4)
  45s  cpu 492% of request (target 70%)   replicas 4 (desired 4)
Scaled out from 2 to 4 replicas.
```

A full cycle, with load held until the maximum and then stopped (`kubectl get events`). It shows the
configured `behavior`: up by 2 at once, down by one per minute only after the 5-minute window.

```
08:06:32  New size: 4; reason: cpu resource utilization (percentage of request) above target
08:07:02  New size: 5; reason: cpu resource utilization (percentage of request) above target
08:12:19  New size: 4; reason: All metrics below target
08:13:19  New size: 3; reason: All metrics below target
08:14:19  New size: 2; reason: All metrics below target
```

## CI

[`.github/workflows/k8s.yml`](../.github/workflows/k8s.yml) runs on every PR touching the manifests,
the scripts or the image:

- **validate:** `kubectl kustomize` render, then [kubeconform](https://github.com/yannh/kubeconform)
  in strict mode against the Kubernetes 1.36 schemas (11/11 resources valid).
- **e2e:** installs kind v0.33.0 (checksum-verified), then runs the same `kind-up.sh`,
  `k8s-verify.sh`, `k8s-rollout-demo.sh` and `k8s-hpa-demo.sh` a reviewer would. The outputs go to
  the job summary, and pods, events and descriptions are dumped on failure.

The outputs above were captured on a local kind cluster running Kubernetes v1.31 (kind v0.24, before
the node image was pinned). CI runs the identical scripts on the pinned v1.36.4.

## How this changes for production on EKS

| Concern | Local (this repo) | Production on EKS |
|---------|-------------------|-------------------|
| Cluster & nodes | kind, 3 Docker containers | EKS across 3 AZs, private subnets. Nodes from **Karpenter** (right-sized, Spot for stateless, consolidation) or managed node groups with Cluster Autoscaler. Bottlerocket or AL2023 AMIs, IMDSv2 with hop limit 1. |
| Ingress | Contour, hostPort, plain HTTP | **AWS Load Balancer Controller**: an ALB from the Ingress (or Gateway API), TLS from **ACM**, AWS WAF, **external-dns** for Route 53. Or keep Contour/Envoy behind an NLB if Envoy features are needed. ALB idle timeout (60 s) < app keep-alive (65 s), already handled. |
| Secrets | `secretGenerator` from a git-ignored file | **External Secrets Operator** syncing from **AWS Secrets Manager / SSM Parameter Store**, authenticated with the pod's IAM role. Values never touch git. EKS envelope encryption of Secrets with a KMS key. Rotation happens in Secrets Manager, and the hash-suffixed name or a reloader rolls the pods. |
| Pod IAM | none needed | **IRSA or EKS Pod Identity**: the ServiceAccount maps to an IAM role scoped to exactly what the app needs. Pods never borrow the node's role (IMDS hop limit 1 blocks them). |
| Images | built locally, `kind load` | ECR (immutable tags, scan on push), pulled by digest. An admission policy (Kyverno or Sigstore policy-controller) admits only images signed by the release pipeline. |
| Autoscaling | HPA on CPU, metrics-server | HPA (CPU, or request rate via KEDA / Prometheus Adapter) plus **Karpenter** adding nodes when pods are pending. Requests tuned from real usage with VPA in recommendation mode. |
| Availability | spread across 2 nodes | `topologySpreadConstraints` on `topology.kubernetes.io/zone` (and hostname). The PDB keeps managed node-group or Karpenter upgrades and drains safe. |
| Network policy | kindnet | Amazon VPC CNI network policies (or Cilium). Security groups for pods if pods talk to RDS etc. |
| Delivery | `kubectl apply -k`, `rollout undo` | **GitOps** (Argo CD or Flux) syncing per-environment overlays. A rollback is a git revert of the image tag. **Argo Rollouts** canary with automated analysis on Prometheus error rate and latency. The HPA owns `replicas`, which is ignored in the diff. |
| Observability | Compose stack (separate) | kube-prometheus-stack, or Amazon Managed Prometheus and Grafana. Alloy or Fluent Bit DaemonSet to Loki/CloudWatch. The same dashboards and alert rules, keyed on Kubernetes labels. |
| Policy | Pod Security "restricted" | The same, plus Kyverno or Gatekeeper for org rules: required labels, resource limits present, no `latest` tags, allowed registries only. |
