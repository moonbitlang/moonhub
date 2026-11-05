# Sourced by production.sh: manage the independent local Docker controller too.
DIND_SERVICE=${MOONHUB_DIND_CONTROLLER_SERVICE:-moonhub-dind-controller.service}
DIND_UNIT=/etc/systemd/system/$DIND_SERVICE
DIND_ENABLED=0
DIND_KEEP_PAUSED=0
DIND_PREVIOUS_CONTROLLER=''
DIND_BACKUP=''
discover_dind() {
  [[ "$DIND_SERVICE" =~ ^[a-zA-Z0-9_-]+\.service$ ]] || return 1
  if ! systemctl cat "$DIND_SERVICE" >/dev/null 2>&1; then return; fi
  [ -f "$DIND_UNIT" ] && [ -z "$(systemctl show "$DIND_SERVICE" -p DropInPaths --value)" ] || {
    printf 'Local Docker controller needs one managed unit without drop-ins: %s\n' "$DIND_UNIT" >&2; return 1;
  }
  local metadata
  metadata=$(python3 "$ROOT/deploy/controller-unit.py" --docker-inspect "$DIND_UNIT")
  [ "$(jq -r .server <<< "$metadata")" = "$MOONHUB_SERVER" ] || {
    printf 'Local Docker controller belongs to another server.\n' >&2; return 1;
  }
  DIND_NAME=$(jq -r .name <<< "$metadata")
  DIND_BINARY=$(jq -r .binary <<< "$metadata")
  DIND_SOCKET=$(jq -r .docker_host <<< "$metadata")
  DIND_STATE=$(jq -r .state_dir <<< "$metadata")
  DIND_ENABLED=1
}
prepare_dind() {
  [ "$DIND_ENABLED" = 1 ] || return 0
  DIND_START_TIMEOUT=${MOONHUB_DIND_START_TIMEOUT:-180}
  [[ "$DIND_START_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$DIND_START_TIMEOUT" -le 600 ] || {
    printf 'Docker controller start timeout must be 0 through 600 seconds.\n' >&2; return 1;
  }
  python3 "$ROOT/deploy/controller-unit.py" --docker-render "$DIND_UNIT" "$LOCAL_RUNNER_IMAGE" > "$CONTROLLER_STAGE/dind.service"
  # Load and verify before pausing claims; preserve the previous image for recovery.
  docker save "$LOCAL_RUNNER_IMAGE" | docker -H "$DIND_SOCKET" load
  [ "$(docker -H "$DIND_SOCKET" image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$LOCAL_RUNNER_IMAGE")" = "$REVISION" ] || {
    printf 'Local Docker task image does not match the production release.\n' >&2; return 1;
  }
}
stop_dind() {
  [ "$DIND_ENABLED" = 1 ] || return 0
  DIND_BACKUP=$backup/dind
  mkdir -m 700 "$DIND_BACKUP"
  cp -p "$DIND_UNIT" "$DIND_BACKUP/controller.service"
  cp -p "$DIND_BINARY" "$DIND_BACKUP/moonhub-runner"
  cp -a "$DIND_STATE" "$DIND_BACKUP/state"
  DIND_KEEP_PAUSED=1
  systemctl stop "$DIND_SERVICE"
  [ -z "$(docker -H "$DIND_SOCKET" ps -aq --filter 'name=^moonhub-pipeline-')" ] || {
    printf 'Local Docker task containers remain; refusing the production switch.\n' >&2; return 1;
  }
  DIND_PREVIOUS_CONTROLLER=$(docker exec -i --user git "$PROJECT-web-1" node --no-warnings - retire "$DIND_NAME" < "$ROOT/deploy/production-dind-state.cjs")
}
install_dind() {
  [ "$DIND_ENABLED" = 1 ] || return 0
  docker exec -i --user git "$PROJECT-web-1" node --no-warnings - image "$DIND_NAME" "$LOCAL_RUNNER_IMAGE" < "$ROOT/deploy/production-dind-state.cjs" > "$backup/dind/image.json"
  install -m 755 "$CONTROLLER_STAGE/moonhub-runner" "$DIND_BINARY.new"
  mv "$DIND_BINARY.new" "$DIND_BINARY"
  install -m 644 "$CONTROLLER_STAGE/dind.service" "$DIND_UNIT.new"
  mv "$DIND_UNIT.new" "$DIND_UNIT"
  systemctl daemon-reload
}
verify_dind() {
  [ "$DIND_ENABLED" = 1 ] || return 0
  cmp -s "$CONTROLLER_STAGE/moonhub-runner" "$DIND_BINARY" || {
    printf 'Local Docker controller binary does not match the production release.\n' >&2; return 1;
  }
  local unit
  unit=$(python3 "$ROOT/deploy/controller-unit.py" --docker-inspect "$DIND_UNIT")
  [ "$(jq -r .runner_image <<< "$unit")" = "$LOCAL_RUNNER_IMAGE" ] || return 1
  [ "$(docker -H "$DIND_SOCKET" image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$LOCAL_RUNNER_IMAGE")" = "$REVISION" ] || return 1
  systemctl is-active --quiet "$DIND_SERVICE" || return 1
  docker exec -i --user git "$PROJECT-web-1" node --no-warnings - verify "$DIND_NAME" "$LOCAL_RUNNER_IMAGE" "$DIND_PREVIOUS_CONTROLLER" < "$ROOT/deploy/production-dind-state.cjs"
}
start_dind() {
  [ "$DIND_ENABLED" = 1 ] || return 0
  systemctl start "$DIND_SERVICE"
  local deadline=$((SECONDS + DIND_START_TIMEOUT))
  until verify_dind > "$backup/dind/verification.log" 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      cat "$backup/dind/verification.log" >&2
      printf 'Local Docker controller failed release verification; recovery backup: %s/dind\n' "$backup" >&2
      return 1
    fi
    sleep 5
  done
  DIND_KEEP_PAUSED=0
  cat "$backup/dind/verification.log"
}
