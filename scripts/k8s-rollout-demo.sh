#!/usr/bin/env bash
#
# k8s-rollout-demo.sh - prove a zero-downtime rolling update and a rollback.
#
# While a probe sends a request through the Ingress every ~50 ms, it:
#   1. rolls the Deployment to a new image version (kubectl set image)
#   2. rolls it back (kubectl rollout undo)
# and then reports every HTTP status and version the probe saw. Any non-200
# response means the rollout was not zero-downtime, and the script exits 1.
#
# Usage: scripts/k8s-rollout-demo.sh [new-tag]   (default 0.2.0; run kind-up.sh first)

set -euo pipefail

readonly NS=devops-task
readonly DEPLOY=deployment/devops-task-api
readonly CLUSTER=devops-task
readonly URL=${URL:-http://127.0.0.1:8088/}
readonly HOST_HEADER=devops-task.localtest.me
readonly NEW_TAG=${1:-0.2.0}
readonly NEW_IMAGE="devops-task-api:${NEW_TAG}"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK=$(mktemp -d)
PROBE_PID=""
cleanup() {
  if [[ -n $PROBE_PID ]]; then
    kill "$PROBE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

run() { # print a command like a terminal session, then run it
  printf '\n$ %s\n' "$*"
  "$@"
}

probe() { # one line per request: <status> <version> <seconds>
  local out code secs version
  while true; do
    rm -f "$WORK/body"
    # HTTP 000 = connection error or no response within 5s: counted as failed.
    # (Latency is reported separately; on a laptop VM it spikes regardless of rollouts.)
    out=$(curl -s -o "$WORK/body" -w '%{http_code} %{time_total}' --max-time 5 -H "Host: $HOST_HEADER" "$URL" || true)
    read -r code secs <<<"$out"
    version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$WORK/body" 2>/dev/null || true)
    printf '%s %s %s\n' "${code:-000}" "${version:--}" "${secs:-5}" >>"$WORK/probe.log"
    sleep 0.05
  done
}

served() { # status/version counts and slowest response since line $1 of the probe log
  tail -n "+$1" "$WORK/probe.log" | awk '{print $1, $2}' | sort | uniq -c |
    awk '{printf "    %6d x HTTP %s  version %s\n", $1, $2, $3}'
  tail -n "+$1" "$WORK/probe.log" | awk '$3 > max {max = $3} END {printf "    slowest response: %.3fs\n", max}'
}

old_image=$(kubectl -n "$NS" get "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Current image: $old_image   ->   new image: $NEW_IMAGE"
# Label the revision we start from (it shows up in `rollout history`).
kubectl -n "$NS" annotate "$DEPLOY" kubernetes.io/change-cause="running ${old_image}" --overwrite >/dev/null

if ! docker image inspect "$NEW_IMAGE" >/dev/null 2>&1; then
  docker build -q --build-arg "APP_VERSION=${NEW_TAG}" -t "$NEW_IMAGE" . >/dev/null
fi
kind load docker-image "$NEW_IMAGE" --name "$CLUSTER" >/dev/null

: >"$WORK/probe.log"
probe &
PROBE_PID=$!
sleep 3

echo
echo "### 1. Rolling update to $NEW_TAG (traffic flowing the whole time)"
start=$(($(wc -l <"$WORK/probe.log") + 1))
update_start=$start
run kubectl -n "$NS" set image "$DEPLOY" "api=${NEW_IMAGE}"
run kubectl -n "$NS" rollout status "$DEPLOY" --timeout=180s
# Annotated after the rollout, so only the new ReplicaSet records the reason
# (annotating first would stamp it on the old revision too).
kubectl -n "$NS" annotate "$DEPLOY" kubernetes.io/change-cause="set image ${NEW_IMAGE}" --overwrite >/dev/null
sleep 3
echo "  Responses during the update:"
served "$start"

run kubectl -n "$NS" rollout history "$DEPLOY"

echo
echo "### 2. Roll back with kubectl rollout undo"
start=$(($(wc -l <"$WORK/probe.log") + 1))
rollback_start=$start
run kubectl -n "$NS" rollout undo "$DEPLOY"
run kubectl -n "$NS" rollout status "$DEPLOY" --timeout=180s
kubectl -n "$NS" annotate "$DEPLOY" kubernetes.io/change-cause="rollout undo to ${old_image}" --overwrite >/dev/null
sleep 3
echo "  Responses during the rollback:"
served "$start"

run kubectl -n "$NS" rollout history "$DEPLOY"

kill "$PROBE_PID" 2>/dev/null || true
PROBE_PID=""

run kubectl -n "$NS" get pods -o wide

total=$(wc -l <"$WORK/probe.log")
failed=$(awk '$1 != "200"' "$WORK/probe.log" | wc -l)
slowest=$(awk '$3 > max {max = $3} END {printf "%.3f", max}' "$WORK/probe.log")
echo
echo "### Result: $total requests through the Ingress, $failed not answered with 200 (slowest ${slowest}s)"
if ((failed > 0)); then
  # Every failure, also those outside the two phases above (warm-up, between them).
  echo "  Not 200 (request number: status, seconds); the update began at request" \
    "$update_start, the rollback at request $rollback_start:"
  awk '$1 != "200" {printf "    %d: HTTP %s, %ss\n", NR, $1, $3}' "$WORK/probe.log" | head -n 50
fi
((failed == 0))
