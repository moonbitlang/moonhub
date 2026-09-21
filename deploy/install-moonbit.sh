#!/bin/sh
set -eu

version=${1:?Usage: install-moonbit.sh VERSION}
case "${MOONHUB_USE_CN_MIRRORS:-0}" in
  0) origin=https://cli.moonbitlang.com ;;
  1) origin=https://cli.moonbitlang.cn ;;
  *) printf 'MOONHUB_USE_CN_MIRRORS must be 0 or 1\n' >&2; exit 1 ;;
esac

# The official regional script also selects the matching toolchain/core host.
installer=$(mktemp "${TMPDIR:-/tmp}/moonhub-install.XXXXXX")
trap 'rm -f "$installer"' EXIT
printf 'Installing MoonBit %s from %s\n' "$version" "$origin"
curl --fail --silent --show-error --location --connect-timeout 30 --max-time 120 --retry 2 \
  "$origin/install/unix.sh" --output "$installer"
bash "$installer" "$version"
