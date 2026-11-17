#!/usr/bin/env bash
#
# deploy.sh - run the app container on an EC2 host with a health-gated,
# automatic rollback. Installed as /usr/local/bin/deploy-app by the instance's
# user data and invoked by the release workflow through SSM Run Command.
#
# Exit codes: 0  deployed and healthy
#             1  new release unhealthy, previous release restored
#             2  usage or configuration error
#             3  new release unhealthy and rollback impossible or failed

set -Eeuo pipefail

readonly CONTAINER=devops-task-api
readonly CONF=${DEPLOY_CONF:-/etc/devops-task/deploy.conf}
readonly STATE_DIR=${DEPLOY_STATE_DIR:-/var/lib/devops-task}
readonly HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-60}

# Set by load_config from $CONF.
AWS_REGION="" LOG_GROUP="" HOST_PORT="" APP_ENV_FILE=""

log() { printf '%s [deploy-app] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() {
  log "ERROR: $1"
  exit "${2:-2}"
}
trap 'log "ERROR: unexpected failure at line $LINENO"' ERR

usage() {
  cat <<'EOF'
Usage: deploy-app <image>      Deploy <image>; roll back automatically if it fails its health check
       deploy-app --rollback   Redeploy the previously running release
       deploy-app --current    Print the image that is currently running
       deploy-app --help

Reads AWS_REGION, LOG_GROUP, HOST_PORT and APP_ENV_FILE from $DEPLOY_CONF
(default: /etc/devops-task/deploy.conf).

Exit codes: 0 deployed, 1 failed but rolled back, 2 usage/config error,
            3 failed and could not roll back
EOF
}

load_config() {
  [[ -r $CONF ]] || die "config file $CONF is missing or unreadable"
  # shellcheck source=/dev/null
  source "$CONF"
  local var
  for var in AWS_REGION LOG_GROUP HOST_PORT APP_ENV_FILE; do
    [[ -n ${!var} ]] || die "$var is not set in $CONF"
  done
}

current_image() {
  docker container inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true
}

ecr_login() {
  local registry=${1%%/*}
  # Only ECR needs a login; the instance role provides the credentials.
  [[ $registry == *.dkr.ecr.*.amazonaws.com ]] || return 0
  aws ecr get-login-password --region "$AWS_REGION" |
    docker login --username AWS --password-stdin "$registry" >/dev/null
}

stop_container() {
  if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    # SIGTERM first so in-flight requests drain; SIGKILL only after 30s.
    docker stop --time 30 "$CONTAINER" >/dev/null
    docker rm "$CONTAINER" >/dev/null
  fi
}

run_container() {
  local image=$1
  docker run --detach --name "$CONTAINER" \
    --restart unless-stopped \
    --publish "${HOST_PORT}:8080" \
    --env-file "$APP_ENV_FILE" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory 256m --cpus 0.5 \
    --log-driver awslogs \
    --log-opt awslogs-region="$AWS_REGION" \
    --log-opt awslogs-group="$LOG_GROUP" \
    --log-opt tag='{{.Name}}/{{.ID}}' \
    --log-opt mode=non-blocking \
    --log-opt max-buffer-size=4m \
    "$image" >/dev/null
}

# Health is checked through the published host port, i.e. the same path real
# traffic takes, not just the container's internal HEALTHCHECK.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  until curl --silent --fail --max-time 2 "http://127.0.0.1:${HOST_PORT}/health" >/dev/null; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 2
  done
}

record_release() {
  local new=$1 prev=$2
  install -d -m 0755 "$STATE_DIR"
  if [[ -n $prev && $prev != "$new" ]]; then
    printf '%s\n' "$prev" >"$STATE_DIR/previous_image"
  fi
  printf '%s\n' "$new" >"$STATE_DIR/current_image"
}

# Keep the running and the previous image (instant rollback); drop older ones.
prune_images() {
  local current=$1 previous=${2:-} image
  while read -r image; do
    [[ $image == "$current" || $image == "$previous" ]] && continue
    docker rmi "$image" >/dev/null 2>&1 || true
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' "${current%:*}")
  docker image prune --force >/dev/null || true
}

deploy() {
  local new=$1 prev
  prev=$(current_image)
  log "deploying $new (currently running: ${prev:-nothing})"

  ecr_login "$new"
  # Pull before stopping the old container to keep the switch-over short.
  docker pull --quiet "$new" >/dev/null
  stop_container
  run_container "$new"

  if wait_healthy; then
    record_release "$new" "$prev"
    prune_images "$new" "$prev"
    log "deploy succeeded: $new is healthy"
    return 0
  fi

  log "$new failed its health check within ${HEALTH_TIMEOUT}s; last log lines:"
  docker logs --tail 30 "$CONTAINER" 2>&1 || true
  if [[ -z $prev || $prev == "$new" ]]; then
    die "no previous release to roll back to" 3
  fi

  log "rolling back to $prev"
  stop_container
  run_container "$prev"
  wait_healthy || die "rollback release $prev is unhealthy too" 3
  log "rollback succeeded: $prev is serving again"
  exit 1
}

rollback() {
  local target
  [[ -r $STATE_DIR/previous_image ]] || die "no previous release recorded in $STATE_DIR" 3
  target=$(<"$STATE_DIR/previous_image")
  log "rollback requested"
  deploy "$target"
}

main() {
  case ${1:-} in
  -h | --help) usage ;;
  --current) current_image ;;
  --rollback)
    load_config
    rollback
    ;;
  "" | -*)
    usage >&2
    exit 2
    ;;
  *)
    load_config
    deploy "$1"
    ;;
  esac
}

main "$@"
