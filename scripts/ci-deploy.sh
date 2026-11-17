#!/usr/bin/env bash
#
# ci-deploy.sh - deploy one release to one environment's EC2 host, from CI.
#
#   1. find the environment's running instance by its tags
#   2. run deploy-app on it through SSM Run Command; the host health-checks the
#      new container and restores the previous release by itself on failure
#   3. smoke-test the public endpoint from outside: /health must answer and /
#      must report the version we just deployed
#   4. if that fails, roll the host back (deploy-app --rollback)
#   5. on success, record the image in SSM Parameter Store, so a replaced host
#      boots straight into this release
#
# Needs AWS credentials for the environment's deploy role and AWS_REGION.
# Exit codes: 0 deployed, 1 deploy failed (rolled back where possible), 2 usage.

set -Eeuo pipefail

readonly PROJECT=${PROJECT:-devops-task}
readonly APP_PORT=${APP_PORT:-80}
readonly SSM_TIMEOUT=${SSM_TIMEOUT:-600}
readonly SMOKE_ATTEMPTS=${SMOKE_ATTEMPTS:-10}

ENVIRONMENT="" IMAGE="" VERSION="" INSTANCE_ID="" URL=""

log() { printf '[ci-deploy] %s\n' "$*"; }
fail() {
  printf '::error title=Deploy to %s failed::%s\n' "${ENVIRONMENT:-?}" "$1"
  summary "**${ENVIRONMENT:-?}: deploy of ${VERSION:-?} failed.** $1"
  exit 1
}
summary() {
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}
output() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

usage() {
  echo "Usage: ${0##*/} <staging|production> <image-uri> <version>" >&2
  exit 2
}

find_instance() {
  local found
  found=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" \
    "Name=tag:Environment,Values=$ENVIRONMENT" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,PublicDnsName]' \
    --output text)
  [[ -n $found ]] || fail "no running instance tagged Project=$PROJECT, Environment=$ENVIRONMENT"
  [[ $(wc -l <<<"$found") -eq 1 ]] || fail "expected exactly one instance, found: $found"

  local dns
  read -r INSTANCE_ID dns <<<"$found"
  URL="http://${dns}"
  if [[ $APP_PORT != 80 ]]; then
    URL+=":${APP_PORT}"
  fi
  log "target: $INSTANCE_ID ($URL)"
  output url "$URL"
}

# run_on_host <comment> <command>: run a shell command on the instance through
# SSM, wait for it, print its output, and succeed only if it succeeded.
run_on_host() {
  local comment=$1 cmd=$2 command_id status=Pending
  command_id=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "${comment:0:100}" \
    --parameters "$(jq -cn --arg c "$cmd" '{commands: [$c], executionTimeout: ["900"]}')" \
    --timeout-seconds 120 \
    --query Command.CommandId --output text)
  log "SSM command $command_id: $cmd"

  local deadline=$((SECONDS + SSM_TIMEOUT))
  while true; do
    sleep 5
    status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" \
      --query Status --output text 2>/dev/null || echo Pending)
    case $status in
    Pending | InProgress | Delayed | Cancelling) ;;
    *) break ;;
    esac
    if ((SECONDS >= deadline)); then
      status="still running after ${SSM_TIMEOUT}s"
      break
    fi
  done

  echo "----- output from $INSTANCE_ID -----"
  aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text || true
  echo "----- end of output (status: $status) -----"
  [[ $status == Success ]]
}

smoke_test() {
  local attempt body served
  for ((attempt = 1; attempt <= SMOKE_ATTEMPTS; attempt++)); do
    if curl --silent --fail --max-time 5 "$URL/health" >/dev/null &&
      body=$(curl --silent --fail --max-time 5 "$URL/"); then
      served=$(jq -r '.version // empty' <<<"$body")
      if [[ $served == "$VERSION" ]]; then
        log "smoke test passed: $URL/health is up and / reports $served"
        return 0
      fi
      log "attempt $attempt: / reports version '${served}', expected '$VERSION'"
    else
      log "attempt $attempt: $URL is not answering yet"
    fi
    sleep 3
  done
  return 1
}

record_release() {
  aws ssm put-parameter --name "/$PROJECT/$ENVIRONMENT/release-image" \
    --type String --value "$IMAGE" --overwrite >/dev/null
  log "recorded $IMAGE as the current $ENVIRONMENT release"
}

main() {
  [[ $# -eq 3 ]] || usage
  ENVIRONMENT=$1 IMAGE=$2 VERSION=$3
  [[ $ENVIRONMENT =~ ^(staging|production)$ ]] || usage
  # The image ends up inside a shell command on the host: allow only the
  # characters an image reference can contain.
  [[ $IMAGE =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || fail "invalid image reference: $IMAGE"
  [[ -n ${AWS_REGION:-} ]] || fail "AWS_REGION is not set"

  find_instance

  if ! run_on_host "deploy $VERSION" "/usr/local/bin/deploy-app '$IMAGE'"; then
    fail "deploy-app failed on the host. It restores the previous release by itself; see the output above."
  fi

  if smoke_test; then
    record_release
    summary "**${ENVIRONMENT}: ${VERSION} deployed** to \`$INSTANCE_ID\`, $URL"
    return 0
  fi

  log "external smoke test failed; rolling back"
  if run_on_host "rollback after failed smoke test of $VERSION" "/usr/local/bin/deploy-app --rollback"; then
    fail "smoke test of $VERSION failed from outside; rolled back to the previous release."
  fi
  fail "smoke test of $VERSION failed AND the rollback failed: manual intervention needed."
}

main "$@"
