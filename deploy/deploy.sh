#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if [ -n "${MOONHUB_DEPLOY_ENV_FILE:-}" ] && [ -f "$MOONHUB_DEPLOY_ENV_FILE" ]; then
  # Operator-owned deployment settings: image policy, pipeline toggle and backup path.
  # shellcheck disable=SC1090
  . "$MOONHUB_DEPLOY_ENV_FILE"
fi

PROJECT=${MOONHUB_COMPOSE_PROJECT_NAME:-moonhub}
ENABLE_PIPELINES=${MOONHUB_ENABLE_PIPELINES:-0}
WAIT_TIMEOUT=${MOONHUB_DEPLOY_WAIT_TIMEOUT:-300}
BACKUP_ROOT=${MOONHUB_BACKUP_DIR:-$ROOT/backups}
ROOT_PASSWORD_FILE=${MOONHUB_ROOT_PASSWORD_FILE:-$ROOT/deploy/secrets/root_password}
PROVIDER_TOKEN_FILE=${MOONHUB_PROVIDER_TOKEN_FILE:-$ROOT/deploy/secrets/provider_token}
PROVIDER_NAME=${MOONHUB_PROVIDER_NAME:-dind}
PROVIDER_LABELS=${MOONHUB_PROVIDER_LABELS:-self-hosted,linux}
PROVIDER_REPOSITORIES=${MOONHUB_PROVIDER_REPOSITORIES:-}
RELEASE=${MOONHUB_RELEASE_TAG:-$(git rev-parse --short=12 HEAD)}
RUNTIME_IMAGE=${MOONHUB_IMAGE:-moonhub:$RELEASE}
PROVIDER_IMAGE=${MOONHUB_PROVIDER_IMAGE:-moonhub-provider:$RELEASE}
RUNNER_IMAGE=${MOONHUB_RUNNER_IMAGE:-moonhub-runner:$RELEASE}
BUILD_RUNNER=${MOONHUB_RUNNER_BUILD:-1}

compose=(docker compose --env-file /dev/null --project-name "$PROJECT"
  -f "$ROOT/compose.yaml")
if [ "$ENABLE_PIPELINES" = 1 ]; then
  compose+=( -f "$ROOT/deploy/compose.pipeline.yaml" )
fi

lock_dir=${MOONHUB_DEPLOY_LOCK_DIR:-/tmp/moonhub-deploy.lock}
if ! mkdir "$lock_dir" 2>/dev/null; then
  printf 'Another deployment is already running: %s\n' "$lock_dir" >&2
  exit 1
fi
cleanup_lock() { rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup_lock EXIT

export MOONHUB_IMAGE="$RUNTIME_IMAGE"
export MOONHUB_PROVIDER_IMAGE="$PROVIDER_IMAGE"
export MOONHUB_RUNNER_IMAGE="$RUNNER_IMAGE"
export MOONHUB_ROOT_PASSWORD_FILE="$ROOT_PASSWORD_FILE"
export MOONHUB_PROVIDER_TOKEN_FILE="$PROVIDER_TOKEN_FILE"

usage() {
  cat <<'EOF'
Usage: deploy/deploy.sh <command>

Commands:
  upgrade   Build images, back up volumes, then switch services once.
  build     Build images only; running services are untouched.
  backup    Back up /data and SSH host keys from the running deployment.
  status    Show Compose service status.
  config    Validate the resolved Compose configuration.

Set MOONHUB_ENABLE_PIPELINES=1 to include DinD, provider and Runner deployment.
Set MOONHUB_DEPLOY_ENV_FILE to an operator-owned env file for persistent settings.
When pipelines are enabled, set MOONHUB_PROVIDER_REPOSITORIES to a comma-separated
repository list such as alice/demo; an empty list registers a provider with no work.
EOF
}

require_file() {
  local path=$1 label=$2
  if [ ! -f "$path" ]; then
    printf '%s is missing: %s\n' "$label" "$path" >&2
    exit 1
  fi
}

validate_inputs() {
  require_file "$ROOT_PASSWORD_FILE" "root password secret"
  if [ "$ENABLE_PIPELINES" = 1 ]; then
    require_file "$PROVIDER_TOKEN_FILE" "provider token secret"
    local token
    token=$(tr -d '[:space:]' < "$PROVIDER_TOKEN_FILE")
    if [[ ! "$token" =~ ^[a-f0-9]{64}$ ]]; then
      printf 'Provider token must be exactly 64 lowercase hexadecimal characters\n' >&2
      exit 1
    fi
  fi
  "$@"
}

validate_compose() {
  "${compose[@]}" config --quiet
}

build_images() {
  validate_inputs true
  validate_compose
  printf 'Building Web/SSH image: %s\n' "$RUNTIME_IMAGE"
  "${compose[@]}" build --pull web
  if [ "$ENABLE_PIPELINES" = 1 ]; then
    if [ "$BUILD_RUNNER" = 1 ]; then
      printf 'Building Runner image: %s\n' "$RUNNER_IMAGE"
      docker build --pull --target runner -t "$RUNNER_IMAGE" "$ROOT"
    else
      printf 'Using pre-published Runner image: %s\n' "$RUNNER_IMAGE"
    fi
    printf 'Building provider image: %s\n' "$PROVIDER_IMAGE"
    "${compose[@]}" build --pull pipeline-provider
  fi
}

backup_volumes() {
  local stamp dir web_id ssh_id
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="$BACKUP_ROOT/$stamp-$RELEASE"
  mkdir -p "$dir"
  web_id=$("${compose[@]}" ps -q web 2>/dev/null || true)
  ssh_id=$("${compose[@]}" ps -q ssh 2>/dev/null || true)
  if [ -n "$web_id" ]; then
    docker cp "$web_id:/data" "$dir/data"
  else
    printf 'Web service is not running; skipped /data backup.\n' >&2
  fi
  if [ -n "$ssh_id" ]; then
    docker cp "$ssh_id:/var/lib/moonhub/ssh" "$dir/ssh-host-keys"
  else
    printf 'SSH service is not running; skipped host-key backup.\n' >&2
  fi
  git rev-parse HEAD > "$dir/git-revision"
  printf 'Backup created: %s\n' "$dir"
}

wait_running() {
  local service=$1 id status
  id=$("${compose[@]}" ps -q "$service")
  [ -n "$id" ] || { printf 'Service has no container: %s\n' "$service" >&2; return 1; }
  status=$(docker inspect -f '{{.State.Status}}' "$id")
  [ "$status" = running ] || { printf 'Service is not running: %s (%s)\n' "$service" "$status" >&2; return 1; }
}

load_runner_into_dind() {
  [ "$ENABLE_PIPELINES" = 1 ] || return 0
  if [ "$BUILD_RUNNER" != 1 ]; then
    return 0
  fi
  local dind_id
  dind_id=$("${compose[@]}" ps -q pipeline-docker)
  [ -n "$dind_id" ] || { printf 'DinD container is unavailable\n' >&2; return 1; }
  printf 'Loading Runner image into DinD: %s\n' "$RUNNER_IMAGE"
  docker save "$RUNNER_IMAGE" | docker exec -i "$dind_id" docker load
  docker exec "$dind_id" docker image inspect "$RUNNER_IMAGE" >/dev/null
}

ensure_provider() {
  [ "$ENABLE_PIPELINES" = 1 ] || return 0
  printf 'Ensuring pipeline provider registration: %s\n' "$PROVIDER_NAME"
  "${compose[@]}" exec -T web sh -eu -c '
    umask 077
    token_file=/tmp/moonhub-provider-token
    trap "rm -f \"$token_file\"" EXIT
    cat > "$token_file"
    moonhub pipeline-provider-ensure \
      --name "$1" --token-file "$token_file" \
      --labels "$2" --repositories "$3"
  ' moonhub-provider-ensure "$PROVIDER_NAME" "$PROVIDER_LABELS" "$PROVIDER_REPOSITORIES" < "$PROVIDER_TOKEN_FILE"
}

start_services() {
  # Web, SSH and DinD are started only after all builds and backups succeed.
  if [ "$ENABLE_PIPELINES" = 1 ]; then
    "${compose[@]}" up -d --no-build --force-recreate --remove-orphans \
      web ssh pipeline-docker --wait --wait-timeout "$WAIT_TIMEOUT"
    load_runner_into_dind
    ensure_provider
    "${compose[@]}" up -d --no-build --force-recreate pipeline-provider
    wait_running pipeline-provider
  else
    "${compose[@]}" up -d --no-build --force-recreate --remove-orphans \
      web ssh --wait --wait-timeout "$WAIT_TIMEOUT"
  fi
  wait_running web
  wait_running ssh
}

upgrade() {
  git diff --quiet && git diff --cached --quiet || {
    printf 'Refusing deployment from a dirty worktree. Commit or stash changes first.\n' >&2
    exit 1
  }
  build_images
  printf 'Stopping current services after successful build and backup...\n'
  "${compose[@]}" stop
  backup_volumes
  start_services
  "${compose[@]}" ps
  printf 'Deployment upgraded to %s\n' "$RELEASE"
}

backup() {
  validate_inputs true
  validate_compose
  backup_volumes
}

status() {
  validate_compose
  "${compose[@]}" ps
}

config() {
  validate_inputs true
  "${compose[@]}" config
}

case "${1:-upgrade}" in
  upgrade) upgrade ;;
  build) build_images ;;
  backup) backup ;;
  status) status ;;
  config) config ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
