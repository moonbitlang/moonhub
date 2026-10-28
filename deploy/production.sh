#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
SETTINGS=${MOONHUB_PRODUCTION_ENV_FILE:-$ROOT/deploy/production.env}
[ -f "$SETTINGS" ] || { printf 'Missing production settings: %s\n' "$SETTINGS" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$SETTINGS"
set +a
: "${MOONHUB_COMPOSE_PROJECT_NAME:?}" "${MOONHUB_AWS_REGION:?}" "${MOONHUB_ECR_REPOSITORY:?}"
PROJECT=$MOONHUB_COMPOSE_PROJECT_NAME
[[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || exit 1
REVISION=$(git rev-parse HEAD)
RELEASE=${REVISION:0:12}
WEB_IMAGE=moonhub:$RELEASE
CONTROLLER_IMAGE=moonhub-controller:$RELEASE
LOCAL_RUNNER_IMAGE=moonhub-runner:$RELEASE
TASK_IMAGE=$MOONHUB_ECR_REPOSITORY:$RELEASE
SERVICE=moonhub-runner-controller.service
STATE=${MOONHUB_CONTROLLER_STATE_DIR:-/var/lib/moonhub-runner/controller}
TOKEN=${MOONHUB_REGISTRATION_TOKEN_FILE:-/etc/moonhub-runner/registration-token}
AWS=${MOONHUB_AWS_CLI:-/usr/local/bin/aws}
BUILDER=${MOONHUB_BUILD_CONTAINER:-$PROJECT-buildkit}
CACHE=${MOONHUB_BUILD_CACHE:-$PROJECT-buildkit-cache}
BUILDER_LABEL=${MOONHUB_BUILD_OWNER:-$PROJECT}
BUILD_STAGE=''
BUILDX=''
BUILD_STARTED=0
RESTART_CONTROLLER=0
cleanup() {
  local result=$?
  if [ "$BUILD_STARTED" = 1 ]; then docker stop "$BUILDER" >/dev/null 2>&1 || true; fi
  if [ -n "$BUILDX" ]; then docker buildx rm "$BUILDX" >/dev/null 2>&1 || true; fi
  if [ -n "$BUILD_STAGE" ]; then rm -rf -- "$BUILD_STAGE"; fi
  if [ "$RESTART_CONTROLLER" = 1 ]; then systemctl start "$SERVICE" || true; fi
  rmdir "$LOCK" 2>/dev/null || true
  return "$result"
}
LOCK=${MOONHUB_PRODUCTION_LOCK_DIR:-/tmp/$PROJECT-production.lock}
mkdir "$LOCK" 2>/dev/null || { printf 'Another production operation is running: %s\n' "$LOCK" >&2; exit 1; }
trap cleanup EXIT
clean_checkout() {
  [ -z "$(git status --porcelain --untracked-files=normal)" ] || { printf 'Refusing dirty source checkout.\n' >&2; return 1; }
}
matching_images() {
  local image
  for image in "$WEB_IMAGE" "$LOCAL_RUNNER_IMAGE" "$CONTROLLER_IMAGE"; do
    [ "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null)" = "$REVISION" ] || return 1
  done
}
build() {
  clean_checkout
  if matching_images; then printf 'Matching committed images already exist: %s\n' "$REVISION"; return; fi
  local platform
  platform=$(docker info --format '{{.OSType}}/{{.Architecture}}')
  case "$platform" in linux/x86_64|linux/amd64) platform=linux/amd64 ;; *) printf 'Production ASG build currently requires x86_64 Linux.\n' >&2; return 1 ;; esac
  [ "$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')" -ge 12582912 ] || { printf 'Need 12 GiB free build/backup headroom.\n' >&2; return 1; }
  BUILD_STAGE=$(mktemp -d /tmp/moonhub-production-build.XXXXXX)
  git archive HEAD | tar -xf - -C "$BUILD_STAGE"
  if docker inspect "$BUILDER" >/dev/null 2>&1; then
    docker inspect "$BUILDER" | jq -e --arg owner "$BUILDER_LABEL" '
      .[0] | .Config.Labels["io.moonhub.builder"] == $owner and
      (.HostConfig | .NanoCpus == 2000000000 and .Memory == 4294967296 and
      .MemorySwap == 4294967296 and .PidsLimit == 512 and
      ((.PortBindings // {}) | length == 0) and
      ([.Binds[]? | select(contains("docker.sock"))] | length == 0)) and
      all(.Mounts[]; (.Destination == "/var/lib/buildkit" and .Type == "volume") or (.Destination == "/etc/buildkit/buildkitd.toml" and .Type == "bind" and .RW == false))' >/dev/null || { printf 'Existing builder ownership/limits do not match.\n' >&2; return 1; }
    docker start "$BUILDER" >/dev/null
  else
    docker run -d --name "$BUILDER" --label "io.moonhub.builder=$BUILDER_LABEL" \
      --privileged --cpus 2 --memory 4g --memory-swap 4g --pids-limit 512 \
      --log-opt max-size=10m --log-opt max-file=3 \
      --mount "type=volume,src=$CACHE,dst=/var/lib/buildkit" \
      --mount "type=bind,src=$ROOT/deploy/buildkitd.toml,dst=/etc/buildkit/buildkitd.toml,readonly" \
      "${MOONHUB_BUILDKIT_IMAGE:-moby/buildkit:buildx-stable-1}" --config /etc/buildkit/buildkitd.toml >/dev/null
  fi
  BUILD_STARTED=1
  BUILDX=$PROJECT-production-$$
  docker buildx create --name "$BUILDX" --driver remote "docker-container://$BUILDER" >/dev/null
  docker buildx inspect "$BUILDX" --bootstrap >/dev/null
  jq -n --arg context "$BUILD_STAGE" --arg platform "$platform" --arg revision "$REVISION" \
    --arg web "$WEB_IMAGE" --arg runner "$LOCAL_RUNNER_IMAGE" --arg controller "$CONTROLLER_IMAGE" \
    --arg cn "${MOONHUB_USE_CN_MIRRORS:-0}" --arg moon "${MOONBIT_VERSION:-0.10.17+093cb8f9c}" '
    def app($target; $tag): {context: $context, dockerfile: "Dockerfile", target: $target,
      contexts: {"moonhub-base:local": "target:dependency-base"}, args: {MOONHUB_BASE_IMAGE: "moonhub-base:local"},
      platforms: [$platform], tags: [$tag], output: ["type=docker"], labels: {"org.opencontainers.image.revision": $revision}};
    {group: {default: {targets: ["web", "runner", "controller"]}}, target: {
      "dependency-base": {context: $context, dockerfile: "deploy/base.Dockerfile", platforms: [$platform],
        args: {MOONHUB_USE_CN_MIRRORS: $cn, MOONBIT_VERSION: $moon}},
      web: app("runtime"; $web), runner: app("runner"; $runner), controller: app("runner-controller"; $controller)}}' > "$BUILD_STAGE/bake.json"
  docker buildx bake --allow="fs.read=$BUILD_STAGE" --builder "$BUILDX" --file "$BUILD_STAGE/bake.json" --progress plain
  matching_images
  docker stop "$BUILDER" >/dev/null
  BUILD_STARTED=0
}
publish() {
  matching_images
  local registry=${MOONHUB_ECR_REPOSITORY%%/*}
  "$AWS" ecr get-login-password --region "$MOONHUB_AWS_REGION" | docker login --username AWS --password-stdin "$registry"
  docker tag "$LOCAL_RUNNER_IMAGE" "$TASK_IMAGE"
  docker push "$TASK_IMAGE"
}
web_deploy() {
  local settings
  settings=$(mktemp /tmp/moonhub-web-settings.XXXXXX)
  # production.env is operator-owned shell configuration, never a build input.
  cat "$SETTINGS" > "$settings"
  printf '\nMOONHUB_IMAGE=%q\nMOONHUB_BUILD_IMAGES=0\nMOONHUB_ENABLE_PIPELINES=0\nMOONHUB_SHARED_HOST=0\nMOONHUB_PULL=0\n' "$WEB_IMAGE" >> "$settings"
  local result=0
  MOONHUB_DEPLOY_ENV_FILE=$settings "$ROOT/deploy/deploy.sh" "$@" || result=$?
  rm -f -- "$settings"
  return "$result"
}
install_controller() {
  : "${MOONHUB_SERVER:?}" "${MOONHUB_ASG:?}" "${MOONHUB_LAUNCH_TEMPLATE:?}" "${MOONHUB_INSTANCE_TYPES:?}" "${MOONHUB_PARAMETER_PREFIX:?}"
  [ "${MOONHUB_PROVIDER_SCOPE:-all}" = all ] || { printf 'Production provider must authorize all repositories.\n' >&2; return 1; }
  [ -z "${MOONHUB_PROVIDER_REPOSITORIES:-}" ] || { printf 'All-repository scope cannot include selected repositories.\n' >&2; return 1; }
  matching_images
  install -d -m 700 "$(dirname "$TOKEN")" "$STATE"
  if [ ! -f "$STATE/registered.json" ]; then
    if [ ! -f "$TOKEN" ]; then openssl rand -hex 32 > "$TOKEN"; chmod 600 "$TOKEN"; fi
    docker exec -i --user git "$PROJECT-web-1" sh -eu -c '
      umask 077; token=$(mktemp); trap '\''rm -f "$token"'\'' EXIT; cat > "$token"
      moonhub pipeline-provider-ensure --preserve-existing --name "$1" --token-file "$token" --labels "$2" --scope all --admin "$3"
    ' register "${MOONHUB_PROVIDER_NAME:-asg}" "${MOONHUB_PROVIDER_LABELS:-self-hosted,linux,moonhub-build}" "${MOONHUB_ROOT_USER:-root}" < "$TOKEN"
  fi
  local container
  container=$(docker create --entrypoint /bin/true "$CONTROLLER_IMAGE")
  docker cp "$container:/usr/local/bin/moonhub-runner" /usr/local/bin/moonhub-runner.new
  docker rm "$container" >/dev/null
  chmod 755 /usr/local/bin/moonhub-runner.new
  mv /usr/local/bin/moonhub-runner.new /usr/local/bin/moonhub-runner
  export MOONHUB_TASK_IMAGE=$TASK_IMAGE MOONHUB_CONTROLLER_STATE_DIR=$STATE MOONHUB_REGISTRATION_TOKEN_FILE=$TOKEN
  python3 "$ROOT/deploy/controller-unit.py" > /etc/systemd/system/$SERVICE.new
  chmod 644 /etc/systemd/system/$SERVICE.new
  mv /etc/systemd/system/$SERVICE.new /etc/systemd/system/$SERVICE
  systemctl daemon-reload
  systemctl enable "$SERVICE"
  systemctl restart "$SERVICE"
  systemctl show "$SERVICE" -p ActiveState -p SubState
}
upgrade() {
  clean_checkout
  build
  publish
  local active backup
  active=$(docker exec -i --user git "$PROJECT-web-1" node --no-warnings - < "$ROOT/deploy/active-attempts.cjs")
  [[ "$active" =~ ^[0-9]+$ ]] && [ "$active" = 0 ] || { printf 'Active attempts prevent production switch.\n' >&2; return 1; }
  backup=${MOONHUB_BACKUP_DIR:-$ROOT/backups}/controller-$(date -u +%Y%m%d-%H%M%S)-$RELEASE
  mkdir -m 700 -p "$backup"
  if systemctl cat "$SERVICE" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$SERVICE"; then RESTART_CONTROLLER=1; fi
    systemctl stop "$SERVICE"
    cp /etc/systemd/system/$SERVICE "$backup/"
  fi
  if [ -d "$STATE" ]; then cp -a "$STATE" "$backup/state"; fi
  if [ -f /usr/local/bin/moonhub-runner ]; then cp /usr/local/bin/moonhub-runner "$backup/"; fi
  cp "$SETTINGS" "$backup/production.env"
  # A stopped controller cannot allocate new workers. Registered workers must
  # already be drained so none can claim during Web image export or restart.
  docker exec -i --user git "$PROJECT-web-1" node --no-warnings - "${MOONHUB_PROVIDER_NAME:-asg}" < "$ROOT/deploy/production-readiness.cjs"
  local groups=("$MOONHUB_ASG")
  if [ -n "${MOONHUB_SPOT_ASG:-}" ]; then groups+=("$MOONHUB_SPOT_ASG"); fi
  "$AWS" autoscaling describe-auto-scaling-groups --region "$MOONHUB_AWS_REGION"     --auto-scaling-group-names "${groups[@]}" --output json --no-cli-pager |     jq -e --argjson count "${#groups[@]}" '.AutoScalingGroups | length == $count and all(.[]; .DesiredCapacity == 0 and (.Instances | length == 0))' >/dev/null || {
      printf 'Drain both ASGs to zero before production switch.
' >&2; return 1;
    }
  web_deploy upgrade
  install_controller
  RESTART_CONTROLLER=0
  printf 'Production checkout %s; task image %s; controller backup %s\n' "$REVISION" "$TASK_IMAGE" "$backup"
}
case "${1:-help}" in
  checkout)
    [ "$#" = 2 ] || exit 2
    clean_checkout
    git check-ref-format --branch "$2" >/dev/null
    origin=$(git remote get-url origin)
    if [[ "$origin" = /* ]] && [ -d "$origin" ]; then
      git -c "safe.directory=$origin" fetch --no-tags origin "refs/heads/$2:refs/remotes/origin/$2"
    else
      git fetch --no-tags origin "refs/heads/$2:refs/remotes/origin/$2"
    fi
    git switch "$2"
    git merge --ff-only "refs/remotes/origin/$2"
    git rev-parse HEAD
    ;;
  build) build ;;
  publish) publish ;;
  controller) install_controller ;;
  upgrade) upgrade ;;
  status) web_deploy status; systemctl show "$SERVICE" -p ActiveState -p SubState ;;
  *) printf 'Usage: deploy/production.sh checkout BRANCH | build | publish | controller | upgrade | status\n';;
esac
