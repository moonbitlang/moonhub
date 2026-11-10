#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck source=deploy/recovery.sh
. "$ROOT/deploy/recovery.sh"
# shellcheck source=deploy/base-image.sh
. "$ROOT/deploy/base-image.sh"
# shellcheck source=deploy/shared-build.sh
. "$ROOT/deploy/shared-build.sh"
if [ "${1:-}" = restore ]; then
  shift
  restore_backup "$@"
  exit
fi
RECOVERY_TOOL_REVISION=$(git rev-parse HEAD)
ALLOW_INTERRUPT=0
if [ "${2:-}" = --interrupt-jobs ] && [ "${1:-}" = upgrade ] && [ "$#" = 2 ]; then
  ALLOW_INTERRUPT=1
elif [ "$#" -gt 1 ]; then
  printf 'Only upgrade accepts --interrupt-jobs\n' >&2; exit 1
fi

DEPLOY_ENV=${MOONHUB_DEPLOY_ENV_FILE:-$ROOT/deploy/deploy.env}
if [ -n "${MOONHUB_DEPLOY_ENV_FILE:-}" ] && [ ! -f "$DEPLOY_ENV" ]; then
  printf 'Deployment settings file is missing: %s\n' "$DEPLOY_ENV" >&2
  exit 1
fi
if [ -f "$DEPLOY_ENV" ]; then
  # Operator-owned deployment settings: image policy, pipeline toggle and backup path.
  set -a
  # shellcheck disable=SC1090
  . "$DEPLOY_ENV"
  set +a
fi

PROJECT=${MOONHUB_COMPOSE_PROJECT_NAME:-moonhub}
[[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { printf 'Invalid Compose project name\n' >&2; exit 1; }
ENABLE_PIPELINES=${MOONHUB_ENABLE_PIPELINES:-0}
WAIT_TIMEOUT=${MOONHUB_DEPLOY_WAIT_TIMEOUT:-300}
BACKUP_ROOT=${MOONHUB_BACKUP_DIR:-$ROOT/backups}
BACKUP_KEEP=${MOONHUB_BACKUP_KEEP:-2}
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] && [ "$BACKUP_KEEP" -le 1000 ] || {
  printf 'MOONHUB_BACKUP_KEEP must be an integer from 0 through 1000\n' >&2; exit 1;
}
ROOT_PASSWORD_FILE=${MOONHUB_ROOT_PASSWORD_FILE:-$ROOT/deploy/secrets/root_password}
PROVIDER_TOKEN_FILE=${MOONHUB_PROVIDER_TOKEN_FILE:-$ROOT/deploy/secrets/provider_token}
PROVIDER_NAME=${MOONHUB_PROVIDER_NAME:-dind}
PROVIDER_LABELS=${MOONHUB_PROVIDER_LABELS:-self-hosted,linux}
PROVIDER_SCOPE=${MOONHUB_PROVIDER_SCOPE:-}
PROVIDER_REPOSITORIES=${MOONHUB_PROVIDER_REPOSITORIES:-}
RELEASE=${MOONHUB_RELEASE_TAG:-$(git rev-parse --short=12 HEAD)}
CONFIGURED_IMAGES="${MOONHUB_IMAGE:-}${MOONHUB_PROVIDER_IMAGE:-}${MOONHUB_RUNNER_IMAGE:-}"
RUNTIME_IMAGE=${MOONHUB_IMAGE:-moonhub:$RELEASE}
PROVIDER_IMAGE=${MOONHUB_PROVIDER_IMAGE:-moonhub-provider:$RELEASE}
RUNNER_IMAGE=${MOONHUB_RUNNER_IMAGE:-moonhub-runner:$RELEASE}
BUILD_RUNNER=${MOONHUB_RUNNER_BUILD:-1}
RUNNER_BUILD_TARGET=${MOONHUB_RUNNER_BUILD_TARGET:-runner}
PULL_IMAGES=${MOONHUB_PULL:-1}
BUILD_IMAGES=${MOONHUB_BUILD_IMAGES:-1}
USE_CN_MIRRORS=${MOONHUB_USE_CN_MIRRORS:-0}
REBUILD_BASE=${MOONHUB_BASE_REBUILD:-0}
SHARED_HOST=${MOONHUB_SHARED_HOST:-0}
OIDC_FILE=${MOONHUB_OIDC_CONFIG_FILE:-}

compose=(docker compose --env-file /dev/null --project-name "$PROJECT"
  -f "$ROOT/compose.yaml")
if [ -n "$OIDC_FILE" ]; then
  compose+=( -f "$ROOT/deploy/compose.oidc.yaml" )
fi
if [ "$ENABLE_PIPELINES" = 1 ]; then
  compose+=( -f "$ROOT/deploy/compose.pipeline.yaml" )
fi
if [ "$SHARED_HOST" = 1 ]; then
  [ "${1:-upgrade}" != build-base ] || { printf 'Shared-host dependency builds must run on a separate bounded builder\n' >&2; exit 1; }
  [ "$ENABLE_PIPELINES" = 1 ] || { printf 'Shared-host profile requires pipelines enabled\n' >&2; exit 1; }
  [ -n "${MOONHUB_CGROUP_PARENT:-}" ] && [ -d "${MOONHUB_DIND_STORAGE_DIR:-}" ] || {
    printf 'Shared-host deployment requires a configured cgroup parent and bounded DinD storage directory\n' >&2; exit 1;
  }
  compose+=( -f "$ROOT/deploy/compose.shared-host.yaml" )
fi

for toggle in "$ENABLE_PIPELINES" "$PULL_IMAGES" "$BUILD_IMAGES" "$BUILD_RUNNER" "$REBUILD_BASE" "$SHARED_HOST"; do
  [[ "$toggle" = 0 || "$toggle" = 1 ]] || { printf 'Deployment switches must be 0 or 1\n' >&2; exit 1; }
done
[[ "$USE_CN_MIRRORS" = 0 || "$USE_CN_MIRRORS" = 1 ]] || {
  printf 'MOONHUB_USE_CN_MIRRORS must be 0 or 1\n' >&2; exit 1;
}
case "$RUNNER_BUILD_TARGET" in
  runner|runner-selfhost) ;;
  *) printf 'Runner build target must be runner or runner-selfhost\n' >&2; exit 1 ;;
esac
case "$PROVIDER_SCOPE" in
  ''|selected|all) ;;
  *) printf 'MOONHUB_PROVIDER_SCOPE must be selected or all, or unset to preserve existing scope\n' >&2; exit 1 ;;
esac
if [ "$PROVIDER_SCOPE" = all ] && [ -n "$PROVIDER_REPOSITORIES" ]; then
  printf 'MOONHUB_PROVIDER_REPOSITORIES must be empty when MOONHUB_PROVIDER_SCOPE=all\n' >&2
  exit 1
fi

lock_dir=${MOONHUB_DEPLOY_LOCK_DIR:-/tmp/moonhub-deploy.lock}
if ! mkdir "$lock_dir" 2>/dev/null; then
  printf 'Another deployment is already running: %s\n' "$lock_dir" >&2
  exit 1
fi
BUILD_STAGE=''
SHARED_BUILDER_CONTAINER=''
SHARED_BUILDER_NAME=''
PAUSED_PROVIDER=''
STOPPED_PROVIDER=''
SWITCH_STARTED=0
cleanup_lock() {
  local status=$?
  if [ -n "${BACKUP_DIR:-}" ] && [[ "$(basename "$BACKUP_DIR")" = .partial-* ]]; then
    rm -rf -- "$BACKUP_DIR"
  fi
  if [ -n "$SHARED_BUILDER_CONTAINER" ]; then docker stop "$SHARED_BUILDER_CONTAINER" >/dev/null 2>&1 || true; fi
  if [ -n "$SHARED_BUILDER_NAME" ]; then docker buildx rm "$SHARED_BUILDER_NAME" >/dev/null 2>&1 || true; fi
  if [ -n "$BUILD_STAGE" ]; then rm -rf -- "$BUILD_STAGE"; fi
  if [ -n "$STOPPED_PROVIDER" ] && [ "$SWITCH_STARTED" = 0 ]; then
    docker start "$STOPPED_PROVIDER" >/dev/null || printf 'Provider restart failed; inspect its state.\n' >&2
  fi
  if [ -n "$PAUSED_PROVIDER" ]; then docker unpause "$PAUSED_PROVIDER" >/dev/null 2>&1 || true; fi
  rmdir "$lock_dir" 2>/dev/null || true
  return "$status"
}
trap cleanup_lock EXIT

export MOONHUB_IMAGE="$RUNTIME_IMAGE"
export MOONHUB_PROVIDER_IMAGE="$PROVIDER_IMAGE"
export MOONHUB_RUNNER_IMAGE="$RUNNER_IMAGE"
export MOONHUB_ROOT_PASSWORD_FILE="$ROOT_PASSWORD_FILE"
export MOONHUB_PROVIDER_TOKEN_FILE="$PROVIDER_TOKEN_FILE"
export MOONHUB_USE_CN_MIRRORS="$USE_CN_MIRRORS"
export MOONHUB_OIDC_CONFIG_FILE="$OIDC_FILE"

usage() {
  cat <<'EOF'
Usage: deploy/deploy.sh <command>

Commands:
  upgrade [--interrupt-jobs] Build first, confirm active job interruption, back up, then switch.
  build     Build application images only; running services are untouched.
  build-base Build the dependency base only, or reuse it if already present.
  backup    Back up stopped Web/SSH/provider; keep DinD running for image export.
  restore <backup> [--replace] [--project NAME --http-port PORT --ssh-port PORT --pipeline-prefix A.B.C]
            Restore exact saved images and data; --replace first backs up the target.
  status    Show Compose service status.
  config    Validate the resolved Compose configuration.
  check-oidc Validate the optional OIDC configuration with the matching Web image.

Set MOONHUB_ENABLE_PIPELINES=1 to include DinD, provider and Runner deployment.
Set MOONHUB_RUNNER_BUILD_TARGET=runner-selfhost for MoonHub's own build workflow.
Set MOONHUB_USE_CN_MIRRORS=1 for domestic Debian/MoonBit sources (default: 0).
Set MOONHUB_BASE_REBUILD=1 to refresh the dependency base, including security updates.
Shared-host builds use a dedicated 2 CPU / 4 GiB BuildKit under moonhub.slice (10 GiB total).
Without --interrupt-jobs, active jobs require interactive confirmation; noninteractive runs refuse.
Set MOONHUB_DEPLOY_ENV_FILE to an operator-owned env file for persistent settings.
The default settings file is deploy/deploy.env (ignored by Git).
Set MOONHUB_PROVIDER_SCOPE=all to share the provider across current and future repos.
For selected scope, set MOONHUB_PROVIDER_REPOSITORIES to a comma-separated list.
Omitting scope preserves existing access; new providers default to selected.
An empty selected repository list registers a new provider with no work.
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
  if [ -n "$OIDC_FILE" ]; then
    [[ "$OIDC_FILE" = /* && "$OIDC_FILE" != *','* && "$OIDC_FILE" != *$'\n'* && "$OIDC_FILE" != *$'\r'* && ! -L "$OIDC_FILE" ]] || {
      printf 'OIDC configuration must be an absolute, regular non-symlink file path.\n' >&2; exit 1;
    }
    require_file "$OIDC_FILE" "OIDC configuration"
  fi
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

validate_oidc() {
  [ -n "$OIDC_FILE" ] || return 0
  docker run --rm --network none --read-only --pids-limit 64 --memory 128m --cpus 1 \
    --mount "type=bind,src=$OIDC_FILE,dst=/run/secrets/workflow_oidc,readonly" \
    --entrypoint moonhub "$RUNTIME_IMAGE" oidc-check /run/secrets/workflow_oidc
}

verify_oidc() {
  [ -n "$OIDC_FILE" ] || return 0
  "${compose[@]}" exec -T --user git web node --no-warnings - <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
(async () => {
  const config = JSON.parse(fs.readFileSync('/run/moonhub/workflow-oidc.json', 'utf8'));
  const publicKey = crypto.createPublicKey(config.private_key);
  const kid = crypto.createHash('sha256').update(publicKey.export({type:'spki',format:'der'})).digest('base64url');
  const request = async path => {
    const response = await fetch('http://127.0.0.1:8080' + path, {signal:AbortSignal.timeout(10000)});
    if (!response.ok) throw Error('OIDC endpoint unavailable');
    return response.json();
  };
  const discovery = await request('/.well-known/openid-configuration');
  const jwks = await request('/-/oidc/jwks');
  if (discovery.issuer !== config.issuer || discovery.jwks_uri !== config.issuer + '/-/oidc/jwks' ||
      !jwks.keys.some(key => key.kid === kid && key.alg === 'RS256' && !key.d)) throw Error('OIDC identity mismatch');
  console.log('Workflow OIDC issuer and signing key verified');
})().catch(() => { console.error('Workflow OIDC verification failed'); process.exitCode = 1; });
JS
}

validate_compose() {
  "${compose[@]}" config --quiet
}

build_images() {
  validate_inputs true
  validate_compose
  if [ "$BUILD_IMAGES" != 1 ]; then
    printf 'Using prebuilt images without building: %s / %s / %s\n' \
      "$RUNTIME_IMAGE" "$PROVIDER_IMAGE" "$RUNNER_IMAGE"
    docker image inspect "$RUNTIME_IMAGE" >/dev/null
    if [ "$ENABLE_PIPELINES" = 1 ]; then
      docker image inspect "$PROVIDER_IMAGE" >/dev/null
      docker image inspect "$RUNNER_IMAGE" >/dev/null
      docker image inspect docker:27.5.1-dind >/dev/null
    fi
    return
  fi
  [ -z "$(git status --porcelain --untracked-files=normal)" ] || {
    printf 'Refusing image build from a dirty worktree.\n' >&2; return 1;
  }
  if [ "$SHARED_HOST" = 1 ]; then
    build_shared_images
    return
  fi
  ensure_base_image
  printf 'Building Web/SSH image: %s\n' "$RUNTIME_IMAGE"
  # Never pull a local base tag from a registry during an application build.
  "${compose[@]}" build web
  if [ "$ENABLE_PIPELINES" = 1 ]; then
    # Fetch dependencies before entering the downtime window.
    if [ "$PULL_IMAGES" = 1 ]; then "${compose[@]}" pull pipeline-docker; fi
    if [ "$BUILD_RUNNER" = 1 ]; then
      printf 'Building Runner image: %s\n' "$RUNNER_IMAGE"
      docker build --target "$RUNNER_BUILD_TARGET" --platform "$DOCKER_DEFAULT_PLATFORM" \
        --build-arg "MOONHUB_BASE_IMAGE=$MOONHUB_BASE_IMAGE" -t "$RUNNER_IMAGE" "$ROOT"
    else
      printf 'Using pre-published Runner image: %s\n' "$RUNNER_IMAGE"
      docker pull "$RUNNER_IMAGE"
    fi
    printf 'Building provider image: %s\n' "$PROVIDER_IMAGE"
    "${compose[@]}" build pipeline-provider
  fi
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
  local dind_id
  dind_id=$("${compose[@]}" ps -q pipeline-docker)
  [ -n "$dind_id" ] || { printf 'DinD container is unavailable\n' >&2; return 1; }
  printf 'Loading Runner image into DinD: %s\n' "$RUNNER_IMAGE"
  docker save "$RUNNER_IMAGE" | docker exec -i "$dind_id" docker -H unix:///run/moonhub-docker/docker.sock load
  docker exec "$dind_id" docker -H unix:///run/moonhub-docker/docker.sock image inspect "$RUNNER_IMAGE" >/dev/null
}

ensure_provider() {
  [ "$ENABLE_PIPELINES" = 1 ] || return 0
  printf 'Ensuring pipeline provider registration: %s\n' "$PROVIDER_NAME"
  # These variables expand inside the container, not in the host shell.
  # shellcheck disable=SC2016
  "${compose[@]}" exec -T --user git web sh -eu -c '
    umask 077
    token_file=$(mktemp /tmp/moonhub-provider-token.XXXXXX)
    trap "rm -f \"$token_file\"" EXIT
    cat > "$token_file"
    scope=$5
    set -- --name "$1" --token-file "$token_file" \
      --labels "$2" --repositories "$3" --admin "$4"
    if [ -n "$scope" ]; then set -- "$@" --scope "$scope"; fi
    moonhub pipeline-provider-ensure --preserve-existing "$@"
  ' moonhub-provider-ensure "$PROVIDER_NAME" "$PROVIDER_LABELS" "$PROVIDER_REPOSITORIES" "${MOONHUB_ROOT_USER:-root}" "$PROVIDER_SCOPE" < "$PROVIDER_TOKEN_FILE"
}

start_services() {
  # Web, SSH and DinD are started only after all builds and backups succeed.
  if [ "$ENABLE_PIPELINES" = 1 ]; then
    "${compose[@]}" up -d --no-build --pull never --force-recreate \
      web ssh pipeline-docker --wait --wait-timeout "$WAIT_TIMEOUT"
    load_runner_into_dind
    ensure_provider
    "${compose[@]}" up -d --no-deps --no-build --pull never --force-recreate pipeline-provider
    wait_running pipeline-provider
  else
    "${compose[@]}" up -d --no-build --pull never --force-recreate \
      web ssh --wait --wait-timeout "$WAIT_TIMEOUT"
  fi
  wait_running web
  wait_running ssh
  verify_oidc
}

confirm_pipeline_interruption() {
  local answer
  [ "$ALLOW_INTERRUPT" = 1 ] && return 0
  if [ ! -t 0 ]; then
    printf 'Active Pipeline jobs prevent the switch. Re-run interactively or explicitly use upgrade --interrupt-jobs.\n' >&2
    return 1
  fi
  printf 'Active Pipeline jobs will be interrupted and may need snapshot reruns. Continue upgrade? [y/N] ' >&2
  read -r answer
  case "$answer" in y|Y|yes|YES) ALLOW_INTERRUPT=1 ;; *) printf 'Upgrade cancelled; built images retained.\n' >&2; return 1 ;; esac
}

prepare_pipeline_switch() {
  [ "$ENABLE_PIPELINES" = 1 ] || return 0
  local dind provider web jobs attempts=0
  dind=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=pipeline-docker)
  [ -n "$dind" ] || return 0
  provider=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=pipeline-provider)
  if [ -n "$provider" ]; then
    [ "$(docker inspect -f '{{.State.Paused}}' "$provider")" = false ] || {
      printf 'Provider was already externally paused; leave it unchanged and retry later.\n' >&2; return 1;
    }
    # Freeze claims only at the switch boundary. Job containers live in DinD
    # and continue independently while the operator decides.
    docker pause "$provider" >/dev/null
    PAUSED_PROVIDER=$provider
  fi
  web=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=web)
  [ -n "$web" ] || { printf 'Web must be running to check active attempts.\n' >&2; return 1; }
  attempts=$(docker exec -i --user git "$web" node --no-warnings - "$PROVIDER_NAME" < "$ROOT/deploy/active-attempts.cjs")
  [[ "$attempts" =~ ^[0-9]+$ ]] || { printf 'Invalid active attempt count\n' >&2; return 1; }
  jobs=$(docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock ps -aq)
  if [ -n "$jobs" ] || [ "$attempts" -gt 0 ]; then confirm_pipeline_interruption; fi
  if [ -n "$provider" ]; then
    STOPPED_PROVIDER=$provider
    docker stop "$provider" >/dev/null
    PAUSED_PROVIDER=''
  fi
  if [ -n "$jobs" ]; then
    local job_ids=()
    while IFS= read -r id; do job_ids+=("$id"); done <<< "$jobs"
    docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock stop -t 15 "${job_ids[@]}" >/dev/null
    for id in "${job_ids[@]}"; do
      if docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock container inspect "$id" >/dev/null 2>&1; then
        docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock rm "$id" >/dev/null
      fi
    done
  fi
  [ -z "$(docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock ps -aq)" ] || {
    printf 'Job cleanup is incomplete; Web/SSH remain running.\n' >&2; return 1;
  }
}

upgrade() {
  [ -z "$(git status --porcelain --untracked-files=normal)" ] || {
    printf 'Refusing deployment from a dirty worktree. Commit or stash changes first.\n' >&2
    exit 1
  }
  recovery_requirements
  build_images
  validate_oidc
  prepare_pipeline_switch
  prepare_backup
  printf 'All images ready. Stopping target services for backup and switch...\n'
  quiesce_provider
  SWITCH_STARTED=1
  "${compose[@]}" stop
  finish_backup
  start_services
  prune_backups
  "${compose[@]}" ps
  STOPPED_PROVIDER=''
  printf 'Deployment running Web=%s Provider=%s Runner=%s (checkout %s)\n' "$RUNTIME_IMAGE" "$PROVIDER_IMAGE" "$RUNNER_IMAGE" "$RECOVERY_TOOL_REVISION"
}

backup() {
  validate_inputs true
  validate_compose
  prepare_backup
  finish_backup
  prune_backups
}

status() {
  validate_compose
  "${compose[@]}" ps
  verify_oidc
}

config() {
  validate_inputs true
  "${compose[@]}" config
}

case "${1:-upgrade}" in
  upgrade) upgrade ;;
  build) build_images ;;
  build-base) ensure_base_image ;;
  backup) backup ;;
  status) status ;;
  config) config ;;
  check-oidc) validate_inputs true; validate_oidc ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
