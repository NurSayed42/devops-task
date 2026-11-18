#!/usr/bin/env bash
#
# kind-up.sh - create the local kind cluster and deploy the app. Idempotent:
# re-running it only applies what changed.
#
#   1. kind cluster (1 control plane + 2 workers, host port 8088 -> ingress)
#   2. add-ons: Contour (ingress controller) and metrics-server (for the HPA)
#   3. build the app image and side-load it into the nodes
#   4. create the git-ignored secrets file if missing, then kubectl apply -k
#
# Usage: scripts/kind-up.sh      (from anywhere; needs docker, kind, kubectl)

set -euo pipefail

readonly CLUSTER=devops-task
readonly NS=devops-task
readonly OVERLAY=k8s/overlays/kind

cd "$(dirname "${BASH_SOURCE[0]}")/.."

log() { printf '\n==> %s\n' "$*"; }
die() {
  printf 'kind-up: %s\n' "$*" >&2
  exit 1
}

for cmd in docker kind kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
done

# The image tag the overlay deploys, e.g. newTag: "0.1.0"
tag=$(awk -F'"' '/newTag:/ {print $2}' "$OVERLAY/kustomization.yaml")
[[ -n $tag ]] || die "could not read newTag from $OVERLAY/kustomization.yaml"
image="devops-task-api:${tag}"

log "Cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' already exists"
else
  kind create cluster --config k8s/kind-cluster.yaml --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s

log "Add-ons: Contour + metrics-server"
kubectl apply -k k8s/addons/contour >/dev/null
kubectl apply -k k8s/addons/metrics-server >/dev/null
kubectl -n projectcontour rollout status deployment/contour --timeout=300s
kubectl -n projectcontour rollout status daemonset/envoy --timeout=300s
kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s

log "Image $image"
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build --build-arg "APP_VERSION=${tag}" \
    --build-arg "GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t "$image" .
fi
kind load docker-image "$image" --name "$CLUSTER"

log "Secret"
if [[ ! -f $OVERLAY/secrets.env ]]; then
  # Random value, never committed (the file is git-ignored).
  printf 'APP_SECRET_KEY=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >"$OVERLAY/secrets.env"
  echo "generated $OVERLAY/secrets.env"
else
  echo "using existing $OVERLAY/secrets.env"
fi

log "Deploy"
kubectl apply -k "$OVERLAY"
kubectl -n "$NS" rollout status deployment/devops-task-api --timeout=300s

log "Done"
kubectl -n "$NS" get deploy,pods,svc,ingress,hpa,pdb
cat <<EOF

  curl -H 'Host: devops-task.localtest.me' http://127.0.0.1:8088/
  curl http://devops-task.localtest.me:8088/health      (*.localtest.me resolves to 127.0.0.1)

  Without the ingress: kubectl -n $NS port-forward svc/devops-task-api 8081:80
  Remove everything:   kind delete cluster --name $CLUSTER
EOF
