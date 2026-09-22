#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[ "$(id -u)" = 0 ] || { printf 'Run through sudo.\n' >&2; exit 1; }
[ "$(docker info --format '{{.CgroupDriver}}/{{.CgroupVersion}}')" = systemd/2 ] || {
  printf 'Shared-host setup requires Docker with systemd and cgroup v2.\n' >&2; exit 1;
}
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IMAGE=/srv/moonhub/dind.ext4
MOUNT=/srv/moonhub/dind
for unit in moonhub.slice srv-moonhub-dind.mount; do
  if [ -e "/etc/systemd/system/$unit" ]; then
    cmp -s "$ROOT/$unit" "/etc/systemd/system/$unit" || {
      printf 'Refusing to overwrite an existing different unit: %s\n' "$unit" >&2; exit 1;
    }
  fi
done
install -d -m 0755 /srv/moonhub
if [ ! -e "$IMAGE" ]; then
  available=$(df -B1 --output=avail /srv/moonhub | tail -n 1 | tr -d ' ')
  [ "$available" -ge 36507222016 ] || { printf 'Need 34 GiB free before reserving 12 GiB for DinD.\n' >&2; exit 1; }
  (set -C; : > "$IMAGE")
  fallocate -l 12G "$IMAGE"
  mkfs.ext4 -q -F -E nodiscard "$IMAGE"
else
  [ -f "$IMAGE" ] && [ ! -L "$IMAGE" ] && [ "$(stat -c %s "$IMAGE")" = 12884901888 ] || {
    printf 'Unexpected DinD backing file; refusing to format or resize it.\n' >&2; exit 1;
  }
  [ "$(blkid -s TYPE -o value "$IMAGE")" = ext4 ] || { printf 'Existing DinD backing file is not ext4.\n' >&2; exit 1; }
fi
allocated=$(( $(stat -c %b "$IMAGE") * 512 ))
missing=$((12884901888 - allocated))
if [ "$missing" -gt 0 ]; then
  available=$(df -B1 --output=avail /srv/moonhub | tail -n 1 | tr -d ' ')
  [ "$available" -ge "$((missing + 21474836480))" ] || { printf 'Refusing to reserve DinD storage without 20 GiB root headroom.\n' >&2; exit 1; }
  fallocate -l 12G "$IMAGE"
fi
install -d -m 0755 "$MOUNT"
install -m 0644 "$ROOT/moonhub.slice" /etc/systemd/system/moonhub.slice
install -m 0644 "$ROOT/srv-moonhub-dind.mount" /etc/systemd/system/srv-moonhub-dind.mount
systemctl daemon-reload
systemctl enable --now moonhub.slice srv-moonhub-dind.mount
mountpoint -q "$MOUNT"
install -d -m 0750 "$MOUNT/docker"
systemctl show moonhub.slice -p CPUQuotaPerSecUSec -p MemoryMax -p MemorySwapMax -p TasksMax
df -h "$MOUNT"
