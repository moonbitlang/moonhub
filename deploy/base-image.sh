#!/usr/bin/env bash
# Sourced by deploy.sh. One local base contains all network-fetched build inputs.

ensure_base_image() {
  local hash_command platform key file
  if command -v sha256sum >/dev/null; then
    hash_command=(sha256sum)
  else
    hash_command=(shasum -a 256)
  fi
  platform=${DOCKER_DEFAULT_PLATFORM:-$(docker info --format '{{.OSType}}/{{.Architecture}}')}
  case "$platform" in
    linux/x86_64) platform=linux/amd64 ;;
    linux/aarch64|linux/arm64/v8) platform=linux/arm64 ;;
    linux/amd64|linux/arm64) ;;
    *) printf 'Unsupported base image platform: %s\n' "$platform" >&2; return 1 ;;
  esac
  export DOCKER_DEFAULT_PLATFORM="$platform"
  if [ -n "${MOONHUB_BASE_IMAGE:-}" ]; then
    [ "$REBUILD_BASE" = 0 ] || {
      printf 'Cannot rebuild an operator-supplied MOONHUB_BASE_IMAGE; unset it to use the managed base.\n' >&2
      return 1
    }
    export MOONHUB_BASE_IMAGE
    printf 'Using configured local base image: %s\n' "$MOONHUB_BASE_IMAGE"
    docker image inspect "$MOONHUB_BASE_IMAGE" >/dev/null
    return
  fi
  key=$(
    {
      printf '%s\n' "$platform" "${MOONBIT_VERSION:-0.10.19+8e43a47fb-nightly}" "$USE_CN_MIRRORS"
      if [ "$USE_CN_MIRRORS" = 1 ]; then
        printf '%s\n' "${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian}" \
          "${DEBIAN_SECURITY_MIRROR:-http://mirrors.ustc.edu.cn/debian-security}"
      fi
      for file in deploy/base.Dockerfile deploy/configure-apt.sh deploy/install-moonbit.sh \
        .dockerignore moon.mod js/package.json js/package-lock.json scripts/resolve-dependencies.cjs; do
        "${hash_command[@]}" "$file" || return 1
      done
    } | "${hash_command[@]}"
  )
  key=${key%% *}
  export MOONHUB_BASE_IMAGE="moonhub-base:$key"
  if [ "$REBUILD_BASE" != 1 ] && docker image inspect "$MOONHUB_BASE_IMAGE" >/dev/null 2>&1; then
    printf 'Reusing base image: %s\n' "$MOONHUB_BASE_IMAGE"
  else
    printf 'Building dependency base image: %s\n' "$MOONHUB_BASE_IMAGE"
    local args=(--file "$ROOT/deploy/base.Dockerfile" --platform "$platform"
      --build-arg "MOONBIT_VERSION=${MOONBIT_VERSION:-0.10.19+8e43a47fb-nightly}"
      --build-arg "MOONHUB_USE_CN_MIRRORS=$USE_CN_MIRRORS"
      --build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian}"
      --build-arg "DEBIAN_SECURITY_MIRROR=${DEBIAN_SECURITY_MIRROR:-http://mirrors.ustc.edu.cn/debian-security}")
    if [ "$PULL_IMAGES" = 1 ]; then args+=(--pull); fi
    if [ "$REBUILD_BASE" = 1 ]; then args+=(--no-cache); fi
    docker build "${args[@]}" -t "$MOONHUB_BASE_IMAGE" "$ROOT"
    docker image inspect "$MOONHUB_BASE_IMAGE" >/dev/null
  fi
  # Convenience alias for direct Compose/manual builds after build-base.
  docker tag "$MOONHUB_BASE_IMAGE" moonhub-base:local
}
