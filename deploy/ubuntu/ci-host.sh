#!/bin/bash
# Install as root-owned 0755 /usr/local/libexec/moonhub-ci-host in a dedicated AMI.
# SSM fetches only this instance's tagged bootstrap, then starts this service.
set -Eeuo pipefail
umask 077
[ "$(id -u)" = 0 ]
[ "$#" = 1 ] && [ "$1" = /run/moonhub-runner/bootstrap.json ]
[ ! -L "$1" ] && [ -f "$1" ]
# An outside controller disables IMDS and independently arms the server-side
# claim gate. Do not use a task-editable firewall as the metadata boundary.
for attempt in $(seq 1 120); do
  if ! curl --noproxy '*' --silent --fail --max-time 1 --request PUT \
    --header X-aws-ec2-metadata-token-ttl-seconds:60 \
    http://169.254.169.254/latest/api/token >/dev/null 2>&1; then
    break
  fi
  [ "$attempt" != 120 ] || exit 125
  sleep 1
done
# Drop management services and cached registry login before untrusted execution.
# The instance role must still be limited to own-instance bootstrap/ECR/SSM;
# previously issued STS credentials are not revoked by disabling metadata.
for service in amazon-ssm-agent snap.amazon-ssm-agent.amazon-ssm-agent; do
  if systemctl is-active --quiet "$service.service"; then
    systemctl stop "$service.service"
    ! systemctl is-active --quiet "$service.service"
  fi
done
if [ -f /root/.docker/config.json ]; then
  docker logout >/dev/null 2>&1 || true
  rm -- /root/.docker/config.json
fi
exec /usr/local/bin/moonhub-runner worker --bootstrap-file "$1"
