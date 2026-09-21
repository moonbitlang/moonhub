FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS assets
WORKDIR /src/js
COPY js/package.json js/package-lock.json ./
RUN npm ci
COPY js/ ./
RUN npm run build

FROM debian:bookworm-slim AS debian-base
ARG MOONHUB_USE_CN_MIRRORS=0
ARG DEBIAN_MIRROR=http://mirrors.ustc.edu.cn/debian
ARG DEBIAN_SECURITY_MIRROR=http://mirrors.ustc.edu.cn/debian-security
COPY deploy/configure-apt.sh /tmp/configure-apt.sh
RUN sh /tmp/configure-apt.sh && rm /tmp/configure-apt.sh

FROM debian-base AS toolchain
ARG MOONBIT_VERSION=0.10.14+7d59c7ec9
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential git libssl-dev \
    && rm -rf /var/lib/apt/lists/*
COPY deploy/install-moonbit.sh /tmp/moonhub-install-moonbit.sh
RUN sh /tmp/moonhub-install-moonbit.sh "$MOONBIT_VERSION" && rm /tmp/moonhub-install-moonbit.sh
ENV PATH="/root/.moon/bin:${PATH}"
WORKDIR /src

FROM toolchain AS build
COPY moon.mod moon.pkg ./
RUN moon update
COPY . .
COPY --from=assets /src/assets/ /src/assets/
# Temporary moonc native debug-info workaround; see README.md.
RUN mkdir -p /out && cc -std=c11 -O2 -Wall -Wextra -Werror runner/step-launcher.c -o /out/moonhub-runner-step \
    && moon test --target native --strip -j 1 --deny-warn && moon build --target native --release --deny-warn

FROM debian-base AS runner
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl git build-essential libssl3 util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 runner \
    && useradd --uid 10001 --gid runner --create-home runner \
    && mkdir /workspace && chown runner:runner /workspace
COPY --from=build /src/_build/native/release/build/moonhub.exe /usr/local/bin/moonhub
COPY --from=build /out/moonhub-runner-step /usr/local/bin/moonhub-runner-step
COPY --from=toolchain /root/.moon /opt/moon
COPY LICENSE /usr/share/doc/moonhub/LICENSE
COPY vendor/yaml/LICENSE /usr/share/doc/moonhub/yaml-LICENSE
RUN chmod -R a+rX /opt/moon
ENV PATH="/opt/moon/bin:/usr/local/bin:/usr/bin:/bin"
USER 10001:10001
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/moonhub", "runner"]

FROM runner AS runner-selfhost
USER root
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
USER 10001:10001

FROM debian-base AS provider
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates docker.io gosu \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 provider \
    && useradd --uid 10001 --gid provider --create-home provider \
    && mkdir -p /var/lib/moonhub/provider \
    && chown provider:provider /var/lib/moonhub/provider
COPY --from=build /src/_build/native/release/build/moonhub.exe /usr/local/bin/moonhub
COPY LICENSE /usr/share/doc/moonhub/LICENSE
COPY --chmod=755 deploy/provider-entrypoint.sh /usr/local/bin/moonhub-provider-entrypoint
WORKDIR /var/lib/moonhub/provider
ENTRYPOINT ["/usr/local/bin/moonhub-provider-entrypoint"]

FROM debian-base AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git gosu openssh-server libssl3 tini \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
    && groupadd --gid 10001 git \
    && useradd --uid 10001 --gid git --create-home --shell /bin/sh git \
    && usermod --password '*' git \
    && chown root:root /home/git
COPY --from=build /src/_build/native/release/build/moonhub.exe /usr/local/bin/moonhub
COPY --from=assets /src/assets/ /app/assets/
COPY db/ /app/db/
# Git only records the executable bit, so migration files created under a
# restrictive umask reach the image unreadable to the git user.
RUN chmod -R a+rX /app/db
COPY deploy/sshd_config /etc/ssh/moonhub_sshd_config
COPY --chmod=755 deploy/entrypoint.sh /usr/local/bin/moonhub-entrypoint
COPY --chmod=755 deploy/import-ssh.sh /usr/local/bin/moonhub-import-ssh
COPY --chmod=755 deploy/hooks/pre-receive /usr/local/lib/moonhub/hooks/pre-receive
ENV DB_PATH=/data/moonhub.db \
    MOONHUB_REPO_ROOT=/data/repos \
    MOONHUB_SSH_IMPORT_ROOT=/run/moonhub/ssh-import \
    MAIL_OUTBOX_DIR=/data/mail_outbox
WORKDIR /app
EXPOSE 8080 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/moonhub-entrypoint"]
CMD ["web"]
