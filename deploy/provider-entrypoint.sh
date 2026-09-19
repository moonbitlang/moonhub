#!/bin/sh
set -eu
umask 077
# Compose file secrets retain host permissions. Copy into a private runtime
# directory before dropping root, as the Web entrypoint does for its secret.
install -d -m 0700 -o provider -g provider /run/moonhub-provider
install -m 0600 -o provider -g provider \
  "${MOONHUB_PROVIDER_TOKEN_FILE:-/run/secrets/provider_token}" /run/moonhub-provider/token
install -d -m 0700 -o provider -g provider /var/lib/moonhub/provider
export MOONHUB_PROVIDER_TOKEN_FILE=/run/moonhub-provider/token
exec gosu provider /usr/local/bin/moonhub provider "$@"
