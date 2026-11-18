#!/usr/bin/env bash
#
# k8s-verify.sh - check that the deployed app is reachable and that its
# security controls are actually enforced (not just declared):
#   ingress routing, non-root + read-only rootfs, secret not in env,
#   NetworkPolicy (with a positive control), Pod Security admission, HPA metrics.
#
# Usage: scripts/k8s-verify.sh   (after scripts/kind-up.sh). Exit 1 if any check fails.

set -uo pipefail # no -e: every check runs and reports, then the summary decides

readonly NS=devops-task
readonly URL=${URL:-http://127.0.0.1:8088}
readonly HOST_HEADER=devops-task.localtest.me
readonly TEST_IMAGE=busybox:1.37

passed=0 failed=0
check() { # check <description> <command...>
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$desc"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$desc"
    failed=$((failed + 1))
  fi
}
not() { ! "$@"; }

pod=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=devops-task-api \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
in_pod() { kubectl -n "$NS" exec "$pod" -c api -- sh -c "$1"; }

echo "# Routing"
check "GET / through the Ingress returns the app's JSON" \
  sh -c "curl -sf -H 'Host: $HOST_HEADER' $URL/ | grep -q '\"status\":\"running\"'"
check "GET /health through the Ingress returns 200" \
  curl -sf -H "Host: $HOST_HEADER" "$URL/health"
check "at least 2 replicas are available" \
  sh -c "[ \"\$(kubectl -n $NS get deploy devops-task-api -o jsonpath='{.status.availableReplicas}')\" -ge 2 ]"

echo "# Container hardening (inside $pod)"
# shellcheck disable=SC2016 # single quotes on purpose: $(id -u) must expand inside the pod
check "runs as UID 10001, not root" in_pod '[ "$(id -u)" = 10001 ]'
check "root filesystem is read-only" in_pod 'touch /srv/probe 2>&1 | grep -q "Read-only file system"'
check "/tmp is writable (memory-backed emptyDir)" in_pod 'touch /tmp/probe && rm /tmp/probe'
check "secret is a readable file under /run/secrets/app" in_pod 'test -s /run/secrets/app/APP_SECRET_KEY'
check "secret is not exposed as an environment variable" in_pod '! env | grep -q APP_SECRET_KEY'
check "no Kubernetes API token is mounted" in_pod '! test -e /var/run/secrets/kubernetes.io/serviceaccount/token'

echo "# NetworkPolicy (default deny; only the ingress controller may connect)"
kubectl delete pod np-probe --ignore-not-found --now >/dev/null 2>&1
kubectl run np-probe --restart=Never --image="$TEST_IMAGE" -- sleep 300 >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/np-probe --timeout=120s >/dev/null 2>&1
check "control: a pod in 'default' can reach Envoy (so the network works)" \
  kubectl exec np-probe -- sh -c 'wget -q -S -O /dev/null -T 5 http://envoy.projectcontour.svc/ 2>&1 | grep -q "HTTP/"'
check "a pod in 'default' cannot reach the API service directly" \
  not kubectl exec np-probe -- wget -q -O /dev/null -T 5 http://devops-task-api.devops-task.svc/health
kubectl delete pod np-probe --now >/dev/null 2>&1

echo "# Pod Security admission (namespace enforces 'restricted')"
check "a root pod without a securityContext is rejected by the API server" \
  sh -c "kubectl -n $NS run psa-probe --restart=Never --image=$TEST_IMAGE --dry-run=server -- true 2>&1 | grep -q 'violates PodSecurity'"

echo "# Autoscaling"
check "HPA receives CPU metrics from metrics-server" \
  sh -c "kubectl -n $NS get hpa devops-task-api -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -qE '^[0-9]+$'"

echo
echo "passed: $passed, failed: $failed"
((failed == 0))
