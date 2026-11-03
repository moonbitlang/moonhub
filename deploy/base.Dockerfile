FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6

ARG MOONHUB_USE_CN_MIRRORS=0
ARG DEBIAN_MIRROR=http://mirrors.ustc.edu.cn/debian
ARG DEBIAN_SECURITY_MIRROR=http://mirrors.ustc.edu.cn/debian-security
ARG MOONBIT_VERSION=0.10.19+8e43a47fb-nightly

COPY deploy/configure-apt.sh /tmp/configure-apt.sh
RUN sh /tmp/configure-apt.sh && rm /tmp/configure-apt.sh
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl build-essential git libssl-dev libssl3 util-linux \
    docker.io gosu openssh-server tini \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*

ENV MOON_HOME=/opt/moon \
    PATH=/opt/moon/bin:/usr/local/bin:/usr/bin:/bin
COPY deploy/install-moonbit.sh /tmp/moonhub-install-moonbit.sh
RUN sh /tmp/moonhub-install-moonbit.sh "$MOONBIT_VERSION" \
    && rm /tmp/moonhub-install-moonbit.sh \
    && chmod -R a+rX /opt/moon

# Resolve and download module dependencies without copying application sources.
WORKDIR /src
COPY moon.mod ./
COPY scripts/resolve-dependencies.cjs /src/scripts/resolve-dependencies.cjs
RUN moon update && node scripts/resolve-dependencies.cjs

WORKDIR /src/js
COPY js/package.json js/package-lock.json ./
RUN npm ci --no-audit --no-fund
WORKDIR /src
# Final stages supply their own entrypoint; do not inherit Node's wrapper.
ENTRYPOINT []
CMD ["/bin/bash"]
