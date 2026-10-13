#!/usr/bin/env bash
# Sourced by deploy.sh. The builder has no host Docker socket or application data.

shared_builder_start() {
  [ "$(docker info --format '{{.CgroupDriver}}/{{.CgroupVersion}}')" = systemd/2 ] || {
    printf 'Bounded builds require systemd cgroup v2.\n' >&2; return 1;
  }
  local parent=${MOONHUB_CGROUP_PARENT:?} name="$PROJECT-buildkit" owned
  [[ "$parent" =~ ^[a-zA-Z0-9_.-]+\.slice$ ]] || { printf 'Invalid build cgroup parent\n' >&2; return 1; }
  [ "$(cat "/sys/fs/cgroup/$parent/memory.max")" = 10737418240 ] || {
    printf 'Configure the MoonHub slice with MemoryMax=10G before concurrent builds.\n' >&2; return 1;
  }
  local quota period
  read -r quota period <<< "$(cat "/sys/fs/cgroup/$parent/cpu.max")"
  [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -le "$((period * 4))" ] || {
    printf 'MoonHub aggregate CPU quota must be at most 4 CPUs.\n' >&2; return 1;
  }
  docker buildx version >/dev/null
  if docker container inspect "$name" >/dev/null 2>&1; then
    owned=$(docker inspect -f '{{index .Config.Labels "io.moonhub.builder"}}' "$name")
    [ "$owned" = "$PROJECT" ] || { printf 'Builder container name belongs to another workload.\n' >&2; return 1; }
    docker inspect "$name" | jq -e --arg parent "$parent" '
      .[0].HostConfig | .NanoCpus == 2000000000 and .Memory == 4294967296
      and .MemorySwap == 4294967296 and .PidsLimit == 512 and .CgroupParent == $parent
      and .CgroupnsMode == "private" and ((.PortBindings // {}) | length == 0)' >/dev/null || {
      printf 'Existing builder does not match required hard limits.\n' >&2; return 1;
    }
    docker start "$name" >/dev/null
  else
    docker run -d --name "$name" --label "io.moonhub.builder=$PROJECT" \
      --privileged --cgroupns private --cgroup-parent "$parent" \
      --cpus 2 --memory 4g --memory-swap 4g --pids-limit 512 \
      --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
      --mount "type=volume,src=$PROJECT-buildkit-cache,dst=/var/lib/buildkit" \
      --mount "type=bind,src=$ROOT/deploy/buildkitd.toml,dst=/etc/buildkit/buildkitd.toml,readonly" \
      "${MOONHUB_BUILDKIT_IMAGE:-moby/buildkit:buildx-stable-1}" \
      --config /etc/buildkit/buildkitd.toml >/dev/null
  fi
  SHARED_BUILDER_CONTAINER=$name
  SHARED_BUILDER_NAME="$PROJECT-bounded-$$"
  docker buildx create --name "$SHARED_BUILDER_NAME" --driver remote "docker-container://$name" >/dev/null
  docker buildx inspect "$SHARED_BUILDER_NAME" --bootstrap >/dev/null
}

build_shared_images() {
  [ -z "${MOONHUB_BASE_IMAGE:-}" ] || { printf 'Shared builds resolve their dependency base through Bake; unset MOONHUB_BASE_IMAGE.\n' >&2; return 1; }
  [ -z "${MOONHUB_RELEASE_TAG:-}" ] && [ -z "$CONFIGURED_IMAGES" ] || {
    printf 'Unset fixed image/release overrides for commit-addressed shared builds.\n' >&2; return 1;
  }
  [ "$BUILD_RUNNER" = 1 ] || { printf 'Shared builds must build the matching Runner.\n' >&2; return 1; }
  local image revision
  local all_ready=1
  for image in "$RUNTIME_IMAGE" "$PROVIDER_IMAGE" "$RUNNER_IMAGE"; do
    revision=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null || true)
    if [ "$revision" != "$RECOVERY_TOOL_REVISION" ]; then all_ready=0; break; fi
  done
  if [ "$all_ready" = 1 ]; then
    printf 'Reusing already-built images for committed source %s\n' "$RECOVERY_TOOL_REVISION"
    return 0
  fi
  local platform available minimum_gib=${MOONHUB_BUILD_MIN_FREE_GIB:-12}
  [[ "$minimum_gib" =~ ^[0-9]+$ ]] && [ "$minimum_gib" -le 1048576 ] || {
    printf 'MOONHUB_BUILD_MIN_FREE_GIB must be an integer from 0 through 1048576.\n' >&2; return 1;
  }
  platform=$(docker info --format '{{.OSType}}/{{.Architecture}}')
  case "$platform" in
    linux/x86_64|linux/amd64) platform=linux/amd64 ;;
    linux/aarch64|linux/arm64) platform=linux/arm64 ;;
    *) printf 'Unsupported native build platform: %s\n' "$platform" >&2; return 1 ;;
  esac
  available=$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')
  [ "$available" -ge "$((minimum_gib * 1048576))" ] || { printf 'Need at least %s GiB free for build/export/backup headroom.\n' "$minimum_gib" >&2; return 1; }
  BUILD_STAGE=$(mktemp -d /tmp/moonhub-build.XXXXXX)
  # Build a committed snapshot, never untracked files, deployment settings or secrets.
  git archive HEAD | tar -xf - -C "$BUILD_STAGE"
  shared_builder_start
  jq -n --arg context "$BUILD_STAGE" --arg platform "$platform" --arg revision "$RECOVERY_TOOL_REVISION" \
    --arg web "$RUNTIME_IMAGE" --arg provider "$PROVIDER_IMAGE" --arg runner "$RUNNER_IMAGE" \
    --arg runner_target "$RUNNER_BUILD_TARGET" --arg cn "$USE_CN_MIRRORS" \
    --arg moon "${MOONBIT_VERSION:-0.10.15+943464bfa}" \
    --arg debian "${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian}" \
    --arg security "${DEBIAN_SECURITY_MIRROR:-http://mirrors.ustc.edu.cn/debian-security}" \
    --argjson pull "$PULL_IMAGES" --argjson rebuild "$REBUILD_BASE" '
    def app($target; $tag): {context: $context, dockerfile: "Dockerfile", target: $target,
      contexts: {"moonhub-base:local": "target:dependency-base"},
      args: {MOONHUB_BASE_IMAGE: "moonhub-base:local"},
      platforms: [$platform], tags: [$tag], output: ["type=docker"],
      labels: {"org.opencontainers.image.revision": $revision}};
    {group: {default: {targets: ["web", "provider", "runner"]}}, target: {
      "dependency-base": {context: $context, dockerfile: "deploy/base.Dockerfile", platforms: [$platform],
        pull: ($pull == 1), "no-cache": ($rebuild == 1),
        args: {MOONHUB_USE_CN_MIRRORS: $cn, MOONBIT_VERSION: $moon, DEBIAN_MIRROR: $debian, DEBIAN_SECURITY_MIRROR: $security}},
      web: app("runtime"; $web), provider: app("provider"; $provider), runner: app($runner_target; $runner)}}' > "$BUILD_STAGE/bake.json"
  printf 'Building committed source %s with 2 CPUs / 4 GiB; Pipeline remains available.\n' "$RECOVERY_TOOL_REVISION"
  docker buildx bake --builder "$SHARED_BUILDER_NAME" --file "$BUILD_STAGE/bake.json" --progress plain
  for image in "$RUNTIME_IMAGE" "$PROVIDER_IMAGE" "$RUNNER_IMAGE"; do
    [ "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")" = "$RECOVERY_TOOL_REVISION" ] || {
      printf 'Built image does not match selected commit: %s\n' "$image" >&2; return 1;
    }
  done
  if [ "$PULL_IMAGES" = 1 ]; then "${compose[@]}" pull pipeline-docker; fi
  docker image inspect docker:27.5.1-dind >/dev/null
  docker stop "$SHARED_BUILDER_CONTAINER" >/dev/null
  SHARED_BUILDER_CONTAINER=''
}
