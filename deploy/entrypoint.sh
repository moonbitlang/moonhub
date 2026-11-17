#!/bin/sh
set -eu
umask 077

case "${1:-web}" in
  web)
    install -d -o git -g git -m 0750 /data /data/repos /data/mail_outbox
    install -d -m 0700 -o git -g git /run/moonhub /run/moonhub/ssh-import
    for directory in /run/secrets/ssh-import/*; do
      [ -d "$directory" ] || continue
      [ ! -L "$directory" ] || { printf '%s\n' 'SSH import directories must not be symlinks' >&2; exit 1; }
      team=${directory##*/}
      case "$team" in
        ''|*[!a-z0-9_-]*|[_-]*) printf '%s\n' 'Invalid SSH import team name' >&2; exit 1 ;;
      esac
      [ "${#team}" -le 63 ] || { printf '%s\n' 'SSH import team name is too long' >&2; exit 1; }
      install -d -m 0700 -o git -g git "/run/moonhub/ssh-import/$team"
      for file in id_ed25519 known_hosts allowed_hosts; do
        # Push mirrors use database-backed keys; an import key is optional.
        if [ "$file" = id_ed25519 ] && [ ! -e "$directory/$file" ] && [ ! -L "$directory/$file" ]; then
          continue
        fi
        if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
          printf 'Missing or invalid SSH import file: %s/%s\n' "$team" "$file" >&2
          exit 1
        fi
        install -m 0600 -o git -g git "$directory/$file" "/run/moonhub/ssh-import/$team/$file"
      done
    done
    if [ -n "${MOONHUB_ROOT_PASSWORD_FILE:-}" ]; then
      install -d -m 0700 -o git -g git /run/moonhub
      install -m 0600 -o git -g git "$MOONHUB_ROOT_PASSWORD_FILE" /run/moonhub/root_password
      export MOONHUB_ROOT_PASSWORD_FILE=/run/moonhub/root_password
    fi
    if [ -n "${MOONHUB_OIDC_CONFIG:-}" ]; then
      [ -f "$MOONHUB_OIDC_CONFIG" ] && [ ! -L "$MOONHUB_OIDC_CONFIG" ] || {
        printf '%s\n' 'Missing or invalid workflow OIDC configuration' >&2; exit 1;
      }
      install -m 0600 -o git -g git "$MOONHUB_OIDC_CONFIG" /run/moonhub/workflow-oidc.json
      export MOONHUB_OIDC_CONFIG=/run/moonhub/workflow-oidc.json
    fi
    shift
    exec gosu git moonhub /data/repos --assets /app/assets --host 0.0.0.0 --port 8080 "$@"
    ;;
  ssh)
    idle=${MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS-120}
    maximum=${MOONHUB_SSH_READ_MAX_SECONDS-3600}
    for seconds in "$idle" "$maximum"; do
      case "$seconds" in
        ''|*[!0-9]*) printf '%s\n' 'SSH read timeouts must be integers between 1 and 2147483 seconds' >&2; exit 1 ;;
      esac
      while [ "${seconds#0}" != "$seconds" ]; do seconds=${seconds#0}; done
      # Bound the digit count before shell integer comparisons (including overflow).
      [ -n "$seconds" ] && [ "${#seconds}" -le 7 ] && [ "$seconds" -ge 1 ] && [ "$seconds" -le 2147483 ] || {
        printf '%s\n' 'SSH read timeouts must be integers between 1 and 2147483 seconds' >&2; exit 1;
      }
    done
    install -d -m 0755 /run/sshd
    install -d -m 0700 /run/moonhub-sshd
    config=/run/moonhub-sshd/sshd_config
    # Only deployment-controlled, validated values enter sshd's session environment.
    # AcceptEnv remains limited to GIT_PROTOCOL in the static configuration.
    # OpenSSH uses only the first SetEnv directive; extend that same directive.
    sed "s/^SetEnv .*/& MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS=$idle MOONHUB_SSH_READ_MAX_SECONDS=$maximum/" \
      /etc/ssh/moonhub_sshd_config > "$config"
    install -d -m 0700 /var/lib/moonhub/ssh
    key=/var/lib/moonhub/ssh/ssh_host_ed25519_key
    if [ ! -f "$key" ]; then
      ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    chmod 0600 "$key"
    /usr/sbin/sshd -t -f "$config"
    exec /usr/sbin/sshd -D -e -f "$config"
    ;;
  *)
    exec gosu git "$@"
    ;;
esac
