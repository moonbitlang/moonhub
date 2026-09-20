#!/usr/bin/env bash
# Sourced by deploy.sh and copied into each self-contained recovery bundle.
set -Eeuo pipefail
umask 077
RECOVERY_TOOLS=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

recovery_requirements() {
  local tool
  for tool in docker jq; do
    command -v "$tool" >/dev/null || { printf 'Recovery requires %s on PATH\n' "$tool" >&2; return 1; }
  done
  if command -v sha256sum >/dev/null; then
    checksum=(sha256sum)
  elif command -v shasum >/dev/null; then
    checksum=(shasum -a 256)
  else
    printf 'Recovery requires sha256sum or shasum\n' >&2; return 1
  fi
}

prepare_backup() {
  recovery_requirements
  local ids id service destination index image dind runner='' network
  BACKUP_DIR=''
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
  if [ -z "$ids" ]; then
    printf 'No existing deployment to back up.\n'
    return
  fi
  mkdir -p "$BACKUP_ROOT"
  BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/.partial-$(date +%Y%m%d-%H%M%S).XXXXXX")
  mkdir "$BACKUP_DIR/bindings"
  # Docker IDs contain no whitespace; expand the newline-separated selection.
  # shellcheck disable=SC2086
  docker inspect $ids > "$BACKUP_DIR/containers.json"
  local networks=()
  while IFS= read -r network; do networks+=("$network"); done < <(
    jq -r '[.[].NetworkSettings.Networks | keys[]] | unique[]' "$BACKUP_DIR/containers.json")
  docker network inspect "${networks[@]}" > "$BACKUP_DIR/networks.json"
  dind=$(jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] == "pipeline-docker") | .Id' "$BACKUP_DIR/containers.json")
  if [ -n "$dind" ]; then
    if [ "$(docker inspect -f '{{.State.Running}}' "$dind")" != true ]; then
      printf 'Keep DinD running while backing up; stop Web, SSH and provider only.\n' >&2; return 1
    fi
    [ -z "$(docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock ps -aq)" ] || {
      printf 'Drain pipeline jobs before backup or upgrade.\n' >&2; return 1;
    }
    image=$(jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] == "pipeline-provider") |
      .Config.Env[] | select(startswith("MOONHUB_RUNNER_IMAGE=")) | ltrimstr("MOONHUB_RUNNER_IMAGE=")' "$BACKUP_DIR/containers.json")
    runner=$(docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock image inspect -f '{{.Id}}' "$image")
    [[ "$runner" =~ ^sha256:[a-f0-9]{64}$ ]] || { printf 'Cannot resolve deployed Runner image\n' >&2; return 1; }
    docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock save "$runner" > "$BACKUP_DIR/runner.tar"
  fi
  jq --arg runner "$runner" --slurpfile networks "$BACKUP_DIR/networks.json" \
    -f "$RECOVERY_TOOLS/recovery.jq" "$BACKUP_DIR/containers.json" > "$BACKUP_DIR/compose.json"
  while IFS=$'\t' read -r id service index destination; do
    docker cp "$id:$destination" "$BACKUP_DIR/bindings/$service-$index"
  done < <(jq -r '.[] | .Id as $id | .Config.Labels["com.docker.compose.service"] as $service |
    .Mounts | to_entries[] | select(.value.Type == "bind") | [$id, $service, .key, .value.Destination] | @tsv' "$BACKUP_DIR/containers.json")
  [ -z "$(find "$BACKUP_DIR/bindings" -type l -print -quit)" ] || {
    printf 'Recovery bindings must not contain symbolic links\n' >&2; return 1;
  }
  local images=()
  while IFS= read -r image; do images+=("$image"); done < <(jq -r '[.[].Image] | unique[]' "$BACKUP_DIR/containers.json")
  docker image inspect "${images[@]}" > "$BACKUP_DIR/images.json"
  docker save "${images[@]}" > "$BACKUP_DIR/images.tar"
  cp "$RECOVERY_TOOLS/recovery.sh" "$RECOVERY_TOOLS/recovery.jq" "$BACKUP_DIR/"
  if [ -f "${DEPLOY_ENV:-}" ]; then cp "$DEPLOY_ENV" "$BACKUP_DIR/operator.env.reference"; fi
  jq -n --arg project "$PROJECT" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg revision "${RECOVERY_TOOL_REVISION:-unknown}" --arg runner "$runner" \
    --arg provider_name "${PROVIDER_NAME:-dind}" --arg provider_labels "${PROVIDER_LABELS:-self-hosted,linux}" \
    --arg provider_repositories "${PROVIDER_REPOSITORIES:-}" --arg runner_target "${RUNNER_BUILD_TARGET:-runner}" \
    '{format: 1, project: $project, created_at: $created, recovery_tool_revision: $revision,
      runner_image: $runner, provider_name: $provider_name, provider_labels: $provider_labels,
      provider_repositories: $provider_repositories, runner_build_target: $runner_target}' > "$BACKUP_DIR/manifest.json"
  printf 'Recovery images/configuration prepared: %s\n' "$BACKUP_DIR"
}

finish_backup() {
  [ -n "$BACKUP_DIR" ] || return 0
  local id service running final file
  while IFS=$'\t' read -r id service; do
    [ "$service" = pipeline-docker ] && continue
    running=$(docker inspect -f '{{.State.Running}}' "$id")
    [ "$running" = false ] || { printf 'Stop Web/SSH/provider before a consistent backup.\n' >&2; return 1; }
  done < <(jq -r '.[] | [.Id, .Config.Labels["com.docker.compose.service"]] | @tsv' "$BACKUP_DIR/containers.json")
  id=$(jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] == "web") | .Id' "$BACKUP_DIR/containers.json")
  docker cp "$id:/data/." - > "$BACKUP_DIR/data.tar"
  id=$(jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] == "ssh") | .Id' "$BACKUP_DIR/containers.json")
  docker cp "$id:/var/lib/moonhub/ssh/." - > "$BACKUP_DIR/ssh-host-keys.tar"
  (
    cd "$BACKUP_DIR"
    while IFS= read -r -d '' file; do "${checksum[@]}" "$file"; done < <(find . -type f ! -name SHA256SUMS -print0)
  ) > "$BACKUP_DIR/SHA256SUMS"
  final=${BACKUP_DIR/\.partial-/}
  mv "$BACKUP_DIR" "$final"
  BACKUP_DIR=$final
  printf 'Backup created: %s\n' "$BACKUP_DIR"
}

quiesce_provider() {
  [ -n "$BACKUP_DIR" ] || return 0
  local provider dind
  provider=$(jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] == "pipeline-provider") | .Id' "$BACKUP_DIR/containers.json")
  [ -n "$provider" ] || return 0
  docker stop "$provider" >/dev/null
  dind=$(jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] == "pipeline-docker") | .Id' "$BACKUP_DIR/containers.json")
  [ -z "$(docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock ps -aq)" ] || {
    printf 'A job appeared during image export; provider stopped, Web/SSH unchanged. Drain jobs and retry.\n' >&2
    return 1
  }
}
