#!/bin/sh
set -eu
umask 077

case "${1:-web}" in
  web)
    install -d -o git -g git -m 0750 /data /data/repos /data/mail_outbox
    if [ -n "${MOONHUB_ROOT_PASSWORD_FILE:-}" ]; then
      install -d -m 0700 -o git -g git /run/moonhub
      install -m 0600 -o git -g git "$MOONHUB_ROOT_PASSWORD_FILE" /run/moonhub/root_password
      export MOONHUB_ROOT_PASSWORD_FILE=/run/moonhub/root_password
    fi
    shift
    exec gosu git moonhub /data/repos --assets /app/assets --host 0.0.0.0 --port 8080 "$@"
    ;;
  ssh)
    install -d -m 0755 /run/sshd
    install -d -m 0700 /var/lib/moonhub/ssh
    key=/var/lib/moonhub/ssh/ssh_host_ed25519_key
    if [ ! -f "$key" ]; then
      ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    chmod 0600 "$key"
    /usr/sbin/sshd -t -f /etc/ssh/moonhub_sshd_config
    exec /usr/sbin/sshd -D -e -f /etc/ssh/moonhub_sshd_config
    ;;
  *)
    exec gosu git "$@"
    ;;
esac
