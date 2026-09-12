FROM node:24-bookworm-slim AS assets
WORKDIR /src/js
COPY js/package.json js/package-lock.json ./
RUN npm ci
COPY js/ ./
RUN npm run build

FROM debian:bookworm-slim AS toolchain
ARG MOONBIT_VERSION=latest
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential git libssl-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh -o /tmp/install-moonbit.sh \
    && bash /tmp/install-moonbit.sh "$MOONBIT_VERSION" \
    && rm /tmp/install-moonbit.sh
ENV PATH="/root/.moon/bin:${PATH}"
WORKDIR /src

FROM toolchain AS build
COPY moon.mod moon.pkg ./
RUN moon update
COPY . .
COPY --from=assets /src/assets/ /src/assets/
RUN moon test --target native && moon build --target native --release

FROM debian:bookworm-slim AS runtime
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
COPY deploy/sshd_config /etc/ssh/moonhub_sshd_config
COPY --chmod=755 deploy/entrypoint.sh /usr/local/bin/moonhub-entrypoint
ENV DB_PATH=/data/moonhub.db \
    MOONHUB_REPO_ROOT=/data/repos \
    MAIL_TRANSPORT=file \
    MAIL_OUTBOX_DIR=/data/mail_outbox
WORKDIR /app
EXPOSE 8080 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/moonhub-entrypoint"]
CMD ["web"]
