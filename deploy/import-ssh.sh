#!/bin/sh
set -eu
: "${MOONHUB_IMPORT_IDENTITY:?Missing team SSH import identity}"
: "${MOONHUB_IMPORT_KNOWN_HOSTS:?Missing team SSH known hosts}"
exec /usr/bin/ssh -F /dev/null \
  -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
  -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null \
  -o "UserKnownHostsFile=$MOONHUB_IMPORT_KNOWN_HOSTS" \
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
  -o ForwardAgent=no -o ClearAllForwardings=yes -o RequestTTY=no \
  -i "$MOONHUB_IMPORT_IDENTITY" "$@"
