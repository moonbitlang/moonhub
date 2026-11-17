#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  printf 'Usage: bash scripts/linux-runner-tools-smoke.sh IMAGE [IMAGE ...]\n' >&2
  exit 1
fi

# Use the job user's restricted PATH and writable workspace. Tool checks must
# work without root, a writable image or downloads from external services.
for image in "$@"; do
  docker run --rm --network none --read-only --cap-drop=ALL \
    --security-opt no-new-privileges --user 10001:10001 \
    --tmpfs /tmp:rw,exec,nosuid,nodev,size=64m \
    --tmpfs /workspace:rw,exec,nosuid,nodev,size=512m,uid=10001,gid=10001,mode=0700 \
    --env HOME=/workspace/home --workdir /workspace \
    --entrypoint bash -i "$image" -seu <<'SH'
export PATH=/opt/moon/bin:/usr/local/bin:/usr/bin:/bin
mkdir -p "$HOME"
for tool in node npm npx bash curl wget git git-lfs gh ssh scp sftp ssh-agent ssh-add ssh-keygen ssh-keyscan openssl rsync jq \
  gcc g++ make clang clang++ clang-format clang-tidy ld.lld llvm-ar cmake ninja meson pkg-config \
  autoconf automake autoreconf libtool libtoolize bison flex ccache python python3 pip3 \
  zip unzip tar gzip bzip2 xz zstd file patch diff find ps setsid rg; do
  if ! command -v "$tool" >/dev/null; then
    printf 'Missing runner tool: %s\n' "$tool" >&2
    exit 1
  fi
done

test "$(id -u)" = 10001
node --version
/opt/actions/node20/bin/node --version
npm --version
npx --version
git lfs version
clang-format --version
clang-tidy --version
ld.lld --version
llvm-ar --version
meson --version
pkg-config --exists openssl zlib python3

cat > hello.c <<'C'
#include <stdio.h>
int main(void) { puts("c-ok"); return 0; }
C
cat > hello.cpp <<'CPP'
#include <iostream>
#include <vector>
int main() { std::vector<int> v{42}; std::cout << v.at(0) << '\n'; }
CPP
for compiler in gcc clang; do
  "$compiler" -Wall -Wextra -Werror hello.c -o hello-c
  test "$(./hello-c)" = c-ok
done
for compiler in g++ clang++; do
  "$compiler" -std=c++17 -Wall -Wextra -Werror hello.cpp -o hello-cpp
  test "$(./hello-cpp)" = 42
done
ccache gcc hello.c -o hello-cached
test "$(./hello-cached)" = c-ok
cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(runner_tools LANGUAGES C CXX)
add_executable(probe hello.cpp)
CMAKE
cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build
test "$(./build/probe)" = 42

python --version
python3 -m venv venv
venv/bin/python -m pip --version
venv/bin/python -c 'import ssl, sys; assert sys.prefix != sys.base_prefix'

mkdir -p npm-probe/tool
cd npm-probe
cat > package.json <<'JSON'
{"name":"runner-npm-probe","version":"1.0.0","private":true,"scripts":{"test":"node -e \"require('node:assert/strict').equal(require('tool'),42)\""},"dependencies":{"tool":"file:tool"}}
JSON
cat > tool/package.json <<'JSON'
{"name":"tool","version":"1.0.0","main":"index.js","bin":{"runner-tool":"cli.js"}}
JSON
printf 'module.exports = 42;\n' > tool/index.js
printf '#!/usr/bin/env node\nconsole.log("npx-ok");\n' > tool/cli.js
chmod +x tool/cli.js
npm install --package-lock-only --offline --ignore-scripts --no-audit --no-fund
npm ci --offline --ignore-scripts --no-audit --no-fund
npm test
test "$(npx --no-install runner-tool)" = npx-ok
cd ..

ssh -V
ssh -G -T example.invalid > ssh-config
ssh-keygen -q -t ed25519 -N '' -f id_ed25519
eval "$(ssh-agent -s)"
trap 'ssh-agent -k >/dev/null' EXIT
ssh-add id_ed25519
ssh-add -l

printf '{"ready":true}\n' > data.json
test "$(jq -r .ready data.json)" = true
mkdir copied
rsync -a data.json copied/
cmp data.json copied/data.json
zip -q data.zip data.json
unzip -p data.zip data.json > unzipped.json
cmp data.json unzipped.json
for compressor in gzip bzip2 xz zstd; do
  "$compressor" -c data.json > compressed
  "$compressor" -dc compressed > decompressed
  cmp data.json decompressed
done
tar -cf data.tar data.json
tar -xOf data.tar data.json > untarred.json
cmp data.json untarred.json
printf 'LINUX_RUNNER_TOOLS_OK\n'
SH
  printf 'Linux runner tools passed: %s\n' "$image"
done
