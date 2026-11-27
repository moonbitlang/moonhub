ARG UBUNTU_VERSION=24.04

FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS node20
FROM docker:27.5.1-dind@sha256:aa3df78ecf320f5fafdce71c659f1629e96e9de0968305fe1de670e0ca9176ce AS dind
FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS action-dependencies
RUN node -p 'require("node:tls").rootCertificates.join("\n")' > /tmp/moonhub-apt-ca.pem
WORKDIR /opt/moonhub-actions
COPY runner/actions/package.json runner/actions/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# Each supported version uses the corresponding Ubuntu userspace.
FROM ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb AS ubuntu-22.04
FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b AS ubuntu-24.04
FROM ubuntu-${UBUNTU_VERSION} AS environment
ARG UBUNTU_VERSION
# The minimal Ubuntu base has no CA bundle. Borrow one from the pinned Node
# image until Ubuntu installs its own; the Ubuntu archive keyring stays in use.
RUN --mount=type=bind,from=action-dependencies,source=/tmp/moonhub-apt-ca.pem,target=/run/moonhub-apt-ca.pem,ro \
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i '/^URIs:/s|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -i '/^deb /s|http://|https://|g' /etc/apt/sources.list; \
    fi \
    && printf '%s\n' 'Acquire::https::Timeout "30";' 'Acquire::Retries "3";' \
        'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/99moonhub-network \
    && apt-get -o Acquire::https::CaInfo=/run/moonhub-apt-ca.pem update \
    && apt-get -o Acquire::https::CaInfo=/run/moonhub-apt-ca.pem install -y --no-install-recommends \
    bash ca-certificates curl wget git git-lfs gh openssh-client openssl rsync jq \
    build-essential clang clang-format clang-tidy lld llvm cmake ninja-build meson \
    pkg-config autoconf automake libtool libtool-bin bison flex ccache libssl-dev zlib1g-dev \
    python3 python3-dev python3-pip python3-venv python-is-python3 \
    zip unzip tar gzip bzip2 xz-utils zstd file patch diffutils findutils procps util-linux ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 runner \
    && useradd --uid 10001 --gid runner --create-home runner \
    && mkdir /workspace && chown runner:runner /workspace
COPY --from=action-dependencies /usr/local/bin/node /usr/local/bin/node
COPY --from=action-dependencies /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY --from=node20 /usr/local/bin/node /opt/actions/node20/bin/node
COPY --from=action-dependencies /opt/moonhub-actions/node_modules /usr/local/lib/moonhub/actions/node_modules
COPY --chmod=0644 runner/actions/*.mjs /usr/local/lib/moonhub/actions/
ENV PATH=/opt/moon/bin:/usr/local/bin:/usr/bin:/bin
LABEL io.moonhub.runner.environment="ubuntu-${UBUNTU_VERSION}"

# Compile only the standalone runner and its non-Web dependencies.
FROM environment AS native-build
ARG MOONBIT_VERSION=1.0.0-rc1+3c0520448
ENV MOON_HOME=/opt/moon
COPY deploy/install-moonbit.sh /tmp/install-moonbit.sh
RUN sh /tmp/install-moonbit.sh "$MOONBIT_VERSION" && chmod -R a+rX /opt/moon
WORKDIR /src
COPY moon.mod ./
# Retain root-version pins, resolving only this binary's two direct modules.
# Web/database/email dependencies do not belong to the standalone runner.
RUN node -e 'const fs=require("fs"); const source=fs.readFileSync("moon.mod","utf8"); fs.writeFileSync("moon.mod",source.replace(/import \{[^}]*\}/,block => block.split("\n").filter(line => !line.includes("@") || /"moonbitlang\/(async|x)@/.test(line)).join("\n")));' \
    && moon update && moon tree --package > /dev/null
COPY cmd/moonhub-runner/ cmd/moonhub-runner/
COPY filelock/ filelock/
COPY provider/ provider/
COPY runner/ runner/
COPY pipeline/protocol/ pipeline/protocol/
COPY pipeline/environment/ pipeline/environment/
COPY pipeline/actions/ pipeline/actions/
# The standalone source slice intentionally excludes database/Web test fixtures.
RUN node -e 'const fs=require("fs"),path=require("path"); function visit(dir){ for(const item of fs.readdirSync(dir,{withFileTypes:true})){ const file=path.join(dir,item.name); if(item.isDirectory()) visit(file); else if(item.name==="moon.pkg") fs.writeFileSync(file,fs.readFileSync(file,"utf8").replace(/import\s*\{[^}]*\}\s*for\s*"(?:wbtest|test)"/g,"")); }} for(const dir of ["cmd","filelock","provider","runner","pipeline"]) visit(dir);' \
    && moon build --strip -j 1 --deny-warn cmd/moonhub-runner \
    && cc -std=c11 -O2 -Wall -Wextra -Werror runner/step-launcher.c -o /src/step-launcher

FROM environment AS runner
COPY --from=native-build /src/_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe /usr/local/bin/moonhub-runner
COPY --from=native-build /src/step-launcher /usr/local/bin/moonhub-runner-step
COPY --from=native-build /opt/moon /opt/moon
COPY LICENSE /usr/share/doc/moonhub/LICENSE
USER 10001:10001
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/moonhub-runner", "execute"]

FROM runner AS tools-sdk-check
WORKDIR /work
ENTRYPOINT ["node", "scripts/openseek-tools-sdk-smoke.mjs"]

# Explicit privileged profile for single-use Linux CI ASGs only. The outside
# worker/controller enforce one claim and instance retirement. No daemon socket
# from that worker is mounted here; this daemon owns only this job's containers.
FROM runner AS ci-runner
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo docker.io iptables iproute2 gosu kmod \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'runner ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/moonhub-ci \
    && chmod 440 /etc/sudoers.d/moonhub-ci
COPY --from=dind /usr/local/bin/dind /usr/local/libexec/moonhub-dind
COPY deploy/ubuntu/ci-entrypoint.sh /usr/local/libexec/moonhub-ci-entrypoint
RUN chmod 755 /usr/local/libexec/moonhub-ci-entrypoint
LABEL io.moonhub.runner.execution="linux-ci-v1"
ENV PATH=/opt/moon/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT ["/usr/local/libexec/moonhub-ci-entrypoint"]
