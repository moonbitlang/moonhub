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

# This installer owns the fresh image's Moon home. Mirror the index and package
# downloads, but keep publishing/authentication on the official API.
moon_home=${MOON_HOME:-$HOME/.moon}
mkdir -p "$moon_home"
if [ "${MOONHUB_USE_CN_MIRRORS:-0}" = 1 ]; then
  printf '%s\n' '{"download":"https://mirrors.ustc.edu.cn/mooncakes","index":"https://mirrors.ustc.edu.cn/mooncakes.git","api":"https://mooncakes.io"}' > "$moon_home/config.json"
else
  printf '%s\n' '{}' > "$moon_home/config.json"
fi
