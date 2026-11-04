#!/usr/bin/env bash
# Installed root-owned on moonhub-web; invoked only by the scoped SSM document.
set -Eeuo pipefail
umask 077
[[ $# = 1 && $1 =~ ^[0-9a-f]{40}$ ]] || { printf 'Expected a full commit SHA.\n' >&2; exit 2; }
revision=$1
exec 9>/run/lock/moonhub-github-deploy.lock
flock -w 3600 9
mkdir -p /var/log/moonhub
log=$(mktemp /var/log/moonhub/deploy-"$revision".XXXXXX)
# SSM only returns the first 24 KB. Keep the full build log on the host and
# return its tail, including the final verification marker, to Actions.
exec 3>&1
trap 'result=$?; tail -c 16000 "$log" >&3; printf "\nDeployment log: %s\n" "$log" >&3; exit "$result"' EXIT
exec >"$log" 2>&1
cd /srv/moonhub/source
[ -z "$(git status --porcelain --untracked-files=normal)" ] || { printf 'Refusing dirty source checkout.\n' >&2; exit 1; }
[ "$(git remote get-url origin)" = git@github.com:moonbitlang/moonhub.git ] || { printf 'Unexpected production origin.\n' >&2; exit 1; }
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -F /dev/null -i /etc/moonhub/github_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/moonhub/github_known_hosts'
git fetch --no-tags origin refs/heads/master:refs/remotes/origin/master
if [ "$(git rev-parse refs/remotes/origin/master)" != "$revision" ]; then
  printf 'MOONHUB_DEPLOY_SKIPPED:%s (master has advanced)\n' "$revision"
  exit 0
fi
git merge-base --is-ancestor HEAD "$revision" || { printf 'Refusing a non-fast-forward production update.\n' >&2; exit 1; }
git switch master
git merge --ff-only "$revision"
./deploy/production.sh upgrade
./deploy/production.sh status
# Verify both application roles use images built from this exact commit.
set -a
. deploy/production.env
set +a
for service in web ssh; do
  container=$MOONHUB_COMPOSE_PROJECT_NAME-$service-1
  [ "$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$container")" = "$revision" ]
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy ]
done
[ "$(systemctl is-active moonhub-runner-controller.service)" = active ]
curl --fail --silent --show-error --output /dev/null "${MOONHUB_SERVER:?}/-/login"
printf 'MOONHUB_DEPLOY_OK:%s\n' "$revision"
