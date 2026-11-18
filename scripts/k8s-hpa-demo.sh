#!/usr/bin/env bash
#
# k8s-hpa-demo.sh - show the HorizontalPodAutoscaler adding replicas under load.
#
# Runs fortio (a load generator) on the kind Docker network, hitting the app
# through the Ingress (so NetworkPolicy is respected), and prints the HPA every
# 15s until it has scaled out, or until the time limit.
#
# Usage: scripts/k8s-hpa-demo.sh [seconds]   (default 180; run kind-up.sh first)

set -euo pipefail

readonly NS=devops-task
readonly LIMIT=${1:-180}
readonly LOADGEN=hpa-loadgen
readonly FORTIO=fortio/fortio:1.76.1@sha256:67bd926e04360c8ec39854ed1644c26c6d850b616c2f8de285f86fa4940fba3b

trap 'docker rm -f "$LOADGEN" >/dev/null 2>&1 || true' EXIT # stop the load on any exit

hpa() { # jsonpath, not `get hpa` columns: the TARGETS column contains spaces
  kubectl -n "$NS" get hpa devops-task-api -o jsonpath='{"  cpu "}{.status.currentMetrics[0].resource.current.averageUtilization}{"% of request (target 70%)   replicas "}{.status.currentReplicas}{" (desired "}{.status.desiredReplicas}{")\n"}'
}

start_replicas=$(kubectl -n "$NS" get hpa devops-task-api -o jsonpath='{.status.currentReplicas}')
echo "Before load:"
hpa

# 16 connections at up to 400 req/s, sent to Envoy on a worker node.
docker run -d --rm --name "$LOADGEN" --network kind "$FORTIO" load \
  -qps 400 -c 16 -t "${LIMIT}s" -H "Host: devops-task.localtest.me" \
  http://devops-task-worker:80/ >/dev/null
echo "Load started (fortio, 16 connections, up to 400 req/s through the Ingress)"

for ((t = 15; t <= LIMIT; t += 15)); do
  sleep 15
  printf '%4ss' "$t"
  hpa
  replicas=$(kubectl -n "$NS" get hpa devops-task-api -o jsonpath='{.status.currentReplicas}')
  if ((replicas > start_replicas)); then
    echo "Scaled out from $start_replicas to $replicas replicas."
    kubectl -n "$NS" get pods -l app.kubernetes.io/name=devops-task-api -o wide
    kubectl -n "$NS" get events --field-selector reason=SuccessfulRescale \
      -o custom-columns=TIME:.lastTimestamp,EVENT:.message
    exit 0
  fi
done

echo "No scale-out within ${LIMIT}s" >&2
exit 1
