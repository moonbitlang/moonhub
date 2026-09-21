#!/bin/sh
set -eu

case "${MOONHUB_USE_CN_MIRRORS:-0}" in
  0)
    DEBIAN_MIRROR=http://deb.debian.org/debian
    DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security
    ;;
  1)
    DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian}
    DEBIAN_SECURITY_MIRROR=${DEBIAN_SECURITY_MIRROR:-http://mirrors.ustc.edu.cn/debian-security}
    ;;
  *) printf 'MOONHUB_USE_CN_MIRRORS must be 0 or 1\n' >&2; exit 1 ;;
esac

# HTTP bootstraps ca-certificates in Debian slim. APT still verifies archives
# using Debian's bundled signing keys; never mark the mirror as trusted.
for mirror in "$DEBIAN_MIRROR" "$DEBIAN_SECURITY_MIRROR"; do
  case "$mirror" in
    http://?*|https://?*) ;;
    *) printf 'Debian mirror must be an HTTP(S) URL\n' >&2; exit 1 ;;
  esac
  case "$mirror" in
    *[!A-Za-z0-9:/._~-]*) printf 'Debian mirror contains unsupported URL characters\n' >&2; exit 1 ;;
  esac
done

apt_dir=${1:-/etc/apt}
mkdir -p "$apt_dir/sources.list.d" "$apt_dir/apt.conf.d"
printf '%s\n' \
  'Types: deb' \
  "URIs: $DEBIAN_MIRROR" \
  'Suites: bookworm bookworm-updates' \
  'Components: main' \
  'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
  '' \
  'Types: deb' \
  "URIs: $DEBIAN_SECURITY_MIRROR" \
  'Suites: bookworm-security' \
  'Components: main' \
  'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
  > "$apt_dir/sources.list.d/debian.sources"
printf '%s\n' \
  'Acquire::http::Timeout "30";' \
  'Acquire::https::Timeout "30";' \
  'Acquire::Retries "2";' \
  'APT::Update::Error-Mode "any";' \
  > "$apt_dir/apt.conf.d/99moonhub-network"
