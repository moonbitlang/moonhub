#!/bin/sh
set -eu
[ "$(id -u)" = 0 ]
[ "$$" = 1 ]
case " $* " in *' --linux-ci '*) ;; *) echo 'Linux CI profile must be explicitly selected' >&2; exit 125 ;; esac
[ ! -e /var/run/docker.sock ]
mkdir -p /run/moonhub-ci
chmod 755 /run/moonhub-ci
printf 'linux-ci-v1\n' > /run/moonhub-ci/profile
chmod 444 /run/moonhub-ci/profile
# Keep the upstream DinD cgroup initialization. A Unix socket is the only API;
# no Docker credentials, TCP listener, host socket or host filesystem is used.
/usr/local/libexec/moonhub-dind dockerd \
  --host=unix:///var/run/docker.sock --group=runner \
  --exec-opt native.cgroupdriver=cgroupfs > /run/moonhub-ci/docker.log 2>&1 &
daemon=$!
for attempt in $(seq 1 60); do
  kill -0 "$daemon" 2>/dev/null || { cat /run/moonhub-ci/docker.log >&2; exit 125; }
  if docker --host unix:///var/run/docker.sock info >/dev/null 2>&1; then
    # Retain non-root PID 1 for runner process protection. Scripts may use sudo
    # inside this explicit profile; the whole EC2 is treated as untrusted.
    exec gosu 10001:10001 /usr/local/bin/moonhub-runner execute "$@"
  fi
  sleep 1
done
echo 'Job Docker daemon did not become ready' >&2
exit 125
