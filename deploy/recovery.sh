#!/usr/bin/env bash
# Sourced by deploy.sh and copied into each self-contained recovery bundle.
set -Eeuo pipefail
umask 077
RECOVERY_TOOLS=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

recovery_requirements() {
  local tool
  for tool in docker jq tar gzip; do
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

# Image IDs are immutable. Keep one compressed archive per image set and link it
# into each self-contained bundle; copying a bundle elsewhere remains sufficient.
backup_image_archive() {
  local destination=$1 key=$2 cache digest temporary
  shift 2
  cache="$BACKUP_ROOT/.image-cache/$key.tar.gz"
  mkdir -p "$BACKUP_ROOT/.image-cache"
  if [ -f "$cache" ] && [ ! -L "$cache" ] && [ -f "$cache.sha256" ] && [ ! -L "$cache.sha256" ]; then
    digest=$("${checksum[@]}" "$cache")
    if [ "${digest%% *}" = "$(cat "$cache.sha256")" ]; then
      ln "$cache" "$destination"
      printf 'Reusing compressed image archive: %s\n' "$key"
      return
    fi
  fi
  temporary=$(mktemp "$BACKUP_ROOT/.image-cache/.pending-XXXXXX")
  if ! "$@" | gzip -1 -n > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  digest=$("${checksum[@]}" "$temporary")
  mv -f -- "$temporary" "$cache"
  printf '%s\n' "${digest%% *}" > "$cache.sha256"
  ln "$cache" "$destination"
}

# Only complete bundles for this project count toward retention. Run after a
# successful switch, so failed builds/backups/startups retain previous recovery.
prune_backups() {
  local keep=${MOONHUB_BACKUP_KEEP:-2} directory count=0 cache
  [ "$keep" != 0 ] || return 0
  [ -n "${BACKUP_DIR:-}" ] || return 0
  verify_backup_bundle "$BACKUP_DIR"
  count=1
  while IFS= read -r directory; do
    [ "$directory" != "$BACKUP_DIR" ] || continue
    [ -f "$directory/SHA256SUMS" ] && [ ! -L "$directory/manifest.json" ] || continue
    jq -e --arg project "$PROJECT" '.format == 1 and .project == $project' "$directory/manifest.json" >/dev/null 2>&1 || continue
    if ! verify_backup_bundle "$directory" >/dev/null 2>&1; then
      printf 'Skipping damaged backup during retention: %s\n' "$directory" >&2
      continue
    fi
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      printf 'Removing expired backup: %s\n' "$directory"
      rm -rf -- "$directory"
    fi
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??????-??????.*' -print | LC_ALL=C sort -r)
  if [ -d "$BACKUP_ROOT/.image-cache" ]; then
    while IFS= read -r cache; do
      rm -f -- "$cache" "$cache.sha256"
    done < <(find "$BACKUP_ROOT/.image-cache" -type f -name '*.tar.gz' -links 1 -print)
  fi
}

# Restore and retention share the same definition of a complete, intact bundle.
# A marker alone must never let a damaged copy displace a verified recovery point.
verify_backup_bundle() {
  local source=$1 required listed actual
  for required in manifest.json compose.json images.json images.tar data.tar ssh-host-keys.tar recovery.sh recovery.jq SHA256SUMS; do
    [ -f "$source/$required" ] && [ ! -L "$source/$required" ] || { printf 'Missing recovery file: %s\n' "$required" >&2; return 1; }
  done
  [ -z "$(find "$source" -type l -print -quit)" ] || { printf 'Backup must not contain symbolic links\n' >&2; return 1; }
  LC_ALL=C awk 'length($1) != 64 || $1 ~ /[^a-f0-9]/ || $2 !~ /^\.\// || $2 ~ /(^|\/)\.\.(\/|$)/ {exit 1}' "$source/SHA256SUMS" || return 1
  listed=$(LC_ALL=C cut -c 67- "$source/SHA256SUMS" | LC_ALL=C sort)
  actual=$(cd "$source" && find . -type f ! -path ./SHA256SUMS -print | LC_ALL=C sort)
  [ "$listed" = "$actual" ] || { printf 'Backup checksum inventory is incomplete or contains extra files\n' >&2; return 1; }
  (cd "$source" && "${checksum[@]}" -c SHA256SUMS >/dev/null) || return 1
  jq -e '.format == 1 and (.project | type == "string")' "$source/manifest.json" >/dev/null || return 1
  if jq -e '.services | has("pipeline-docker")' "$source/compose.json" >/dev/null; then
    [ -f "$source/runner.tar" ] && [ ! -L "$source/runner.tar" ] || { printf 'Missing pinned Runner image\n' >&2; return 1; }
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
    backup_image_archive "$BACKUP_DIR/runner.tar" "runner-${runner#sha256:}" \
      docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock save "$runner"
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
  jq '[.[].Image] | unique | map({key: ., value: ("moonhub-recovery:" + ltrimstr("sha256:"))}) | from_entries' \
    "$BACKUP_DIR/containers.json" > "$BACKUP_DIR/image-aliases.json"
  local aliases=() alias
  for image in "${images[@]}"; do
    alias="moonhub-recovery:${image#sha256:}"
    docker tag "$image" "$alias"
    aliases+=("$alias")
  done
  # Transport tags bridge classic/config IDs and containerd/manifest IDs. Restore
  # resolves the loaded tags back to immutable local IDs before starting services.
  local image_key
  image_key=$(printf '%s\n' "${images[@]}" | "${checksum[@]}")
  backup_image_archive "$BACKUP_DIR/images.tar" "images-${image_key%% *}" docker save "${aliases[@]}"
  cp "$RECOVERY_TOOLS/recovery.sh" "$RECOVERY_TOOLS/recovery.jq" "$BACKUP_DIR/"
  if [ -f "${DEPLOY_ENV:-}" ]; then cp "$DEPLOY_ENV" "$BACKUP_DIR/operator.env.reference"; fi
  jq -n --arg project "$PROJECT" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg revision "${RECOVERY_TOOL_REVISION:-unknown}" --arg runner "$runner" \
    --arg provider_name "${PROVIDER_NAME:-dind}" --arg provider_labels "${PROVIDER_LABELS:-self-hosted,linux}" \
    --arg provider_scope "${PROVIDER_SCOPE:-}" \
    --arg provider_repositories "${PROVIDER_REPOSITORIES:-}" --arg runner_target "${RUNNER_BUILD_TARGET:-runner}" \
    '{format: 1, project: $project, created_at: $created, recovery_tool_revision: $revision,
      runner_image: $runner, provider_name: $provider_name, provider_labels: $provider_labels,
      provider_scope: $provider_scope,
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
    while IFS= read -r -d '' file; do "${checksum[@]}" "$file"; done < <(find . -type f ! -path ./SHA256SUMS -print0)
  ) > "$BACKUP_DIR/SHA256SUMS"
  final=$(basename "$BACKUP_DIR")
  final="$(dirname "$BACKUP_DIR")/${final#.partial-}"
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

restore_backup() {
  recovery_requirements
  local source=${1:?Usage: recovery.sh restore BACKUP [--replace] [--project NAME --http-port PORT --ssh-port PORT --pipeline-prefix A.B.C]}
  shift
  source=$(CDPATH='' cd -- "$source" && pwd)
  local replace=0 project='' http='' ssh='' prefix='' option
  while [ "$#" -gt 0 ]; do
    option=$1; shift
    case "$option" in
      --replace) replace=1 ;;
      --project|--http-port|--ssh-port|--pipeline-prefix)
        [ "$#" -gt 0 ] || { printf 'Missing value for %s\n' "$option" >&2; return 1; }
        case "$option" in
          --project) project=$1 ;; --http-port) http=$1 ;; --ssh-port) ssh=$1 ;; --pipeline-prefix) prefix=$1 ;;
        esac
        shift ;;
      *) printf 'Unknown restore option: %s\n' "$option" >&2; return 1 ;;
    esac
  done
  [[ "$(basename "$source")" != .partial-* ]] || { printf 'Refusing an incomplete backup\n' >&2; return 1; }
  # No checksum paths may escape the bundle. Backups are trusted operator input,
  # but corrupt or partially copied files must fail before touching services.
  verify_backup_bundle "$source"
  if jq -e '[.services[].cgroup_parent // ""] | any(. != "")' "$source/compose.json" >/dev/null; then
    printf 'This shared-host backup needs a provisioned resource slice and fresh bounded DinD storage; automatic generic restore is refused.\n' >&2
    return 1
  fi
  local original pipelines runner
  original=$(jq -r .project "$source/manifest.json")
  project=${project:-$original}
  [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { printf 'Invalid target project\n' >&2; return 1; }
  pipelines=$(jq -r '.services | has("pipeline-docker")' "$source/compose.json")
  runner=$(jq -r .runner_image "$source/manifest.json")
  if [ "$project" != "$original" ]; then
    [ -n "$http" ] && [ -n "$ssh" ] && { [ "$pipelines" = false ] || [ -n "$prefix" ]; } || {
      printf 'A separate project requires explicit HTTP/SSH ports and pipeline prefix when enabled.\n' >&2; return 1;
    }
  fi
  for option in "$http" "$ssh"; do
    [ -z "$option" ] || { [[ "$option" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$option" -le 65535 ]; } || { printf 'Invalid restore port\n' >&2; return 1; }
  done
  if [ -n "$prefix" ]; then
    [[ "$prefix" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] &&
      jq -en --arg prefix "$prefix" '$prefix | split(".") | all(.[]; tonumber <= 255)' >/dev/null || {
        printf 'Invalid pipeline IPv4 prefix\n' >&2; return 1;
      }
  fi
  RECOVERY_LOCK=${MOONHUB_DEPLOY_LOCK_DIR:-/tmp/moonhub-deploy.lock}
  mkdir "$RECOVERY_LOCK" 2>/dev/null || { printf 'Another deployment is running: %s\n' "$RECOVERY_LOCK" >&2; return 1; }
  trap 'rmdir "$RECOVERY_LOCK" 2>/dev/null || true' EXIT
  local ids
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
  [ -z "$ids" ] || [ "$replace" = 1 ] || { printf 'Target has containers; use --replace to back it up and replace it.\n' >&2; return 1; }
  # Loading by immutable IDs is safe while the target runs and requires no registry.
  docker load -i "$source/images.tar"
  local image alias resolved resolved_images='{}'
  while IFS= read -r image; do
    [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || { printf 'Backup image is not pinned by ID\n' >&2; return 1; }
    alias=$image
    if [ -f "$source/image-aliases.json" ]; then
      alias=$(jq -er --arg image "$image" '.[$image]' "$source/image-aliases.json")
      [ "$alias" = "moonhub-recovery:${image#sha256:}" ] || { printf 'Unexpected image transport tag\n' >&2; return 1; }
    fi
    resolved=$(docker image inspect -f '{{.Id}}' "$alias")
    [[ "$resolved" =~ ^sha256:[a-f0-9]{64}$ ]] || { printf 'Cannot resolve restored image ID\n' >&2; return 1; }
    resolved_images=$(jq -cn --argjson images "$resolved_images" --arg original "$image" --arg resolved "$resolved" '$images + {($original): $resolved}')
  done < <(jq -r '[.services[].image] | unique[]' "$source/compose.json")
  if [ "$pipelines" = true ]; then
    [[ "$runner" =~ ^sha256:[a-f0-9]{64}$ ]] && [ -f "$source/runner.tar" ] || { printf 'Missing pinned Runner image\n' >&2; return 1; }
    # The outer daemon may use containerd image IDs while DinD uses config IDs.
    # Validate the archived config here; load and inspect it only in DinD.
    local runner_config
    runner_config=$(tar -xOf "$source/runner.tar" manifest.json | jq -er 'if length == 1 then .[0].Config else error("Expected one Runner image") end')
    [[ "$runner_config" = "blobs/sha256/${runner#sha256:}" || "$runner_config" = "${runner#sha256:}.json" ]] || {
      printf 'Runner archive does not match its pinned config ID\n' >&2; return 1;
    }
    [ "$(tar -xOf "$source/runner.tar" "$runner_config" | "${checksum[@]}" | cut -d ' ' -f 1)" = "${runner#sha256:}" ] || {
      printf 'Runner config checksum mismatch\n' >&2; return 1;
    }
  fi
  local state_root=${MOONHUB_RECOVERY_STATE_DIR:-$(dirname "$source")/recovered}
  mkdir -p "$state_root"
  local state suffix
  state=$(mktemp -d "$state_root/$project-$(date +%Y%m%d-%H%M%S).XXXXXX")
  state=$(CDPATH='' cd -- "$state" && pwd)
  suffix=$(basename "$state" | tr '[:upper:].' '[:lower:]-')
  printf 'Preparing restored volumes; failure artifacts remain at %s\n' "$state"
  cp -R "$source/bindings" "$state/bindings"
  cp "$source/manifest.json" "$state/manifest.json"
  jq --arg project "$project" --arg original "$original" --arg http "$http" --arg ssh "$ssh" \
    --arg prefix "$prefix" --arg suffix "$suffix" --argjson images "$resolved_images" '
    .services |= with_entries(.value.image = $images[.value.image]) |
    .volumes |= with_entries(.value = {name: ($suffix + "_" + .key)}) |
    if $http != "" then .services.web.ports = [{target: 8080, published: $http, host_ip: "127.0.0.1", protocol: "tcp"}] else . end |
    if $ssh != "" then .services.ssh.ports = [{target: 2222, published: $ssh, host_ip: "127.0.0.1", protocol: "tcp"}] else . end |
    if .networks.pipeline then
      if $project != $original then .networks.pipeline.name = ($project + "_pipeline") else . end |
      if $prefix != "" then
        .networks.pipeline.ipam.config = [{subnet: ($prefix + ".0/24")}] |
        .services.web.networks.pipeline.ipv4_address = ($prefix + ".10") |
        .services["pipeline-docker"].networks.pipeline.ipv4_address = ($prefix + ".11") |
        .services["pipeline-provider"].networks.pipeline.ipv4_address = ($prefix + ".12") |
        .services["pipeline-provider"].environment |= map(if startswith("MOONHUB_RUNNER_SERVER=") then
          "MOONHUB_RUNNER_SERVER=http://" + $prefix + ".10:8080" else . end)
      else . end
    else . end' "$source/compose.json" > "$state/compose.json"
  local restore_compose=(docker compose --env-file /dev/null --project-name "$project" -f "$state/compose.json")
  "${restore_compose[@]}" config --quiet
  if [ "$pipelines" = true ]; then
    local network existing_network
    network=$(jq -r .networks.pipeline.name "$state/compose.json")
    existing_network=$(docker network ls -q --filter "name=^${network}$")
    if [ -n "$existing_network" ]; then
      docker network inspect "$existing_network" > "$state/existing-network.json"
      jq -e --arg project "$project" --slurpfile config "$state/compose.json" '
        length == 1 and .[0].Labels["com.docker.compose.project"] == $project and
        (.[0].IPAM.Config | map(.Subnet) | sort) == ($config[0].networks.pipeline.ipam.config | map(.subnet) | sort)
      ' "$state/existing-network.json" >/dev/null || {
        printf 'Target pipeline network belongs to another project or has a different subnet; restore to a separate project.\n' >&2; return 1;
      }
    fi
  fi
  # Persist the new volume names for future normal upgrades. Original config is
  # retained only as a reference and is never sourced during recovery.
  jq -r --arg project "$project" --arg state "$state" --arg runner "$runner" \
    --slurpfile manifest "$source/manifest.json" '
    def env($service; $key):
      [.services[$service].environment[]? | select(startswith($key + "=")) | ltrimstr($key + "=")][0] // "";
    def binding($service; $target):
      [.services[$service].volumes[] | select(.target == $target) | .source | ltrimstr("./")][0] | $state + "/" + .;
    def port($service): .services[$service].ports[0].published;
    {MOONHUB_COMPOSE_PROJECT_NAME: $project, MOONHUB_BUILD_IMAGES: "1", MOONHUB_PULL: "0",
     MOONHUB_ENABLE_PIPELINES: (if .services["pipeline-docker"] then "1" else "0" end),
     MOONHUB_HTTP_PORT: port("web"), MOONHUB_HTTP_BIND: .services.web.ports[0].host_ip,
     MOONHUB_SSH_PORT: port("ssh"), MOONHUB_SSH_BIND: .services.ssh.ports[0].host_ip,
     MOONHUB_ROOT_USER: env("web"; "MOONHUB_ROOT_USER"),
     MOONHUB_ROOT_PASSWORD_FILE: binding("web"; "/run/secrets/root_password"),
     MOONHUB_SSH_IMPORT_DIR: binding("web"; "/run/secrets/ssh-import"),
     MOONHUB_DATA_VOLUME: .volumes.data.name, MOONHUB_SSH_KEYS_VOLUME: .volumes["ssh-host-keys"].name,
     MOONHUB_SSH_PUBLIC_URL: env("web"; "MOONHUB_SSH_PUBLIC_URL"),
     MOONHUB_SSH_INTERNAL_URL: env("web"; "MOONHUB_SSH_INTERNAL_URL"),
     MOONHUB_IMPORT_TIMEOUT_SECONDS: env("web"; "MOONHUB_IMPORT_TIMEOUT_SECONDS"),
     MOONHUB_WEBHOOK_ALLOWED_ORIGINS: env("web"; "MOONHUB_WEBHOOK_ALLOWED_ORIGINS"),
     MOONHUB_BACKUP_DIR: ($state + "/backups")}
    + (if any(.services.web.volumes[]; .target == "/run/secrets/workflow_oidc") then {
       MOONHUB_OIDC_CONFIG_FILE: binding("web"; "/run/secrets/workflow_oidc")}
      else {} end)
    + (if .services["pipeline-provider"] then {
       MOONHUB_PROVIDER_TOKEN_FILE: binding("pipeline-provider"; "/run/secrets/provider_token"),
       MOONHUB_PROVIDER_NAME: $manifest[0].provider_name, MOONHUB_PROVIDER_LABELS: $manifest[0].provider_labels,
       MOONHUB_PROVIDER_SCOPE: ($manifest[0].provider_scope // ""),
       MOONHUB_PROVIDER_REPOSITORIES: $manifest[0].provider_repositories,
       MOONHUB_RUNNER_BUILD_TARGET: $manifest[0].runner_build_target,
       MOONHUB_RUNNER_MEMORY: env("pipeline-provider"; "MOONHUB_RUNNER_MEMORY"),
       MOONHUB_RUNNER_CPUS: env("pipeline-provider"; "MOONHUB_RUNNER_CPUS"),
       MOONHUB_RUNNER_PIDS_LIMIT: env("pipeline-provider"; "MOONHUB_RUNNER_PIDS_LIMIT"),
       MOONHUB_PIPELINE_PREFIX: (.services.web.networks.pipeline.ipv4_address | split(".")[0:3] | join(".")),
       MOONHUB_PIPELINE_NETWORK: .networks.pipeline.name,
       MOONHUB_PIPELINE_SOCKET_VOLUME: .volumes["pipeline-socket"].name,
       MOONHUB_PIPELINE_CONTROL_VOLUME: .volumes["pipeline-control"].name,
       MOONHUB_PIPELINE_DOCKER_VOLUME: .volumes["pipeline-docker-data"].name}
      else {} end) | to_entries[] | select(.value != null and .value != "") |
      .key + "=" + (.value | gsub("\\$\\$"; "$") | @sh)' "$state/compose.json" > "$state/upgrade.env"
  # Stage into NEW volumes; neither failed extraction nor failed startup destroys
  # the original volumes. The service switch is the only destructive boundary.
  local runtime volume key
  runtime=$(jq -r .services.web.image "$state/compose.json")
  for key in data ssh-host-keys; do
    volume=$(jq -r --arg key "$key" '.volumes[$key].name' "$state/compose.json")
    docker volume create --label "com.docker.compose.project=$project" --label "com.docker.compose.volume=$key" "$volume" >/dev/null
    docker run --rm -i --network none --read-only --entrypoint /bin/sh \
      --mount "type=volume,src=$volume,dst=/restore" "$runtime" \
      -eu -c 'test -z "$(ls -A /restore)"; tar -xpf - --numeric-owner -C /restore' < "$source/$key.tar"
  done
  if [ -n "$ids" ]; then
    PROJECT=$project BACKUP_ROOT=${MOONHUB_BACKUP_DIR:-$(dirname "$source")}
    prepare_backup
    [ -n "$BACKUP_DIR" ] || { printf 'Target disappeared during recovery\n' >&2; return 1; }
    quiesce_provider
    # shellcheck disable=SC2086
    docker stop $ids >/dev/null
    finish_backup
    printf 'Pre-restore backup: %s\n' "$BACKUP_DIR"
  fi
  local wait=${MOONHUB_DEPLOY_WAIT_TIMEOUT:-300}
  printf 'Starting restored deployment. Recovery state retained at %s\n' "$state"
  if [ "$pipelines" = true ]; then
    "${restore_compose[@]}" up -d --no-build --pull never --force-recreate --remove-orphans web ssh pipeline-docker --wait --wait-timeout "$wait"
    local dind
    dind=$("${restore_compose[@]}" ps -q pipeline-docker)
    docker exec -i "$dind" docker -H unix:///run/moonhub-docker/docker.sock load < "$source/runner.tar"
    docker exec "$dind" docker -H unix:///run/moonhub-docker/docker.sock image inspect "$runner" >/dev/null
    # Provider identities/grants are restored from SQLite, never re-registered.
    "${restore_compose[@]}" up -d --no-deps --no-build --pull never --force-recreate pipeline-provider
    local provider
    provider=$("${restore_compose[@]}" ps -q pipeline-provider)
    [ -n "$provider" ] && [ "$(docker inspect -f '{{.State.Status}}' "$provider")" = running ] || {
      printf 'Restored provider failed to start\n' >&2; return 1;
    }
  else
    "${restore_compose[@]}" up -d --no-build --pull never --force-recreate --remove-orphans web ssh --wait --wait-timeout "$wait"
  fi
  "${restore_compose[@]}" ps
  printf 'Restored project %s. Start/status with: docker compose --env-file /dev/null -p %q -f %q\n' "$project" "$project" "$state/compose.json"
  printf 'For subsequent deploy.sh upgrades, use MOONHUB_DEPLOY_ENV_FILE=%q\n' "$state/upgrade.env"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ "${1:-}" = restore ] || { printf 'Usage: bash recovery.sh restore BACKUP [options]\n' >&2; exit 2; }
  shift
  restore_backup "$@"
fi
