#!/usr/bin/env bash
# Launch-template user data. Replace the two @...@ markers before base64 encoding.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends docker.io curl ca-certificates unzip
systemctl enable --now docker
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL --retry 3 https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/moonhub-awscli.zip
  unzip -q /tmp/moonhub-awscli.zip -d /tmp/moonhub-awscli
  /tmp/moonhub-awscli/aws/install
fi
if systemctl list-unit-files snap.amazon-ssm-agent.amazon-ssm-agent.service --no-legend | grep -q amazon-ssm-agent; then
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service
else
  snap install amazon-ssm-agent --classic
  snap start amazon-ssm-agent
fi
IMAGE='@RUNNER_IMAGE@'
REGION='@AWS_REGION@'
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${IMAGE%%/*}"
docker pull "$IMAGE"
container=$(docker create --entrypoint /bin/true "$IMAGE")
trap 'docker rm "$container" >/dev/null 2>&1 || true' EXIT
docker cp "$container:/usr/local/bin/moonhub-runner" /usr/local/bin/moonhub-runner
chmod 755 /usr/local/bin/moonhub-runner
install -d -m 700 /var/lib/moonhub-runner /run/moonhub-runner
printf 'ready\n' > /var/lib/moonhub-runner/image-ready
