ARG MOONHUB_BASE_IMAGE=moonhub-base:local
FROM ${MOONHUB_BASE_IMAGE} AS base
# The dependency base's minimal PATH excludes administration tools needed below.
ENV PATH="/opt/moon/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RUN --network=none command -v groupadd && command -v useradd && command -v usermod && command -v gosu

FROM base AS assets
WORKDIR /src/js
COPY js/ ./
RUN --network=none npm run build

FROM base AS build
COPY . .
COPY --from=assets /src/assets/ /src/assets/
RUN --network=none mkdir -p /out && cc -std=c11 -O2 -Wall -Wextra -Werror runner/step-launcher.c -o /out/moonhub-runner-step \
    && moon build --target native --release --deny-warn

FROM base AS runner
RUN groupadd --gid 10001 runner \
    && useradd --uid 10001 --gid runner --create-home runner \
    && mkdir /workspace && chown runner:runner /workspace
COPY --from=build /src/_build/native/release/build/moonhub.exe /usr/local/bin/moonhub
COPY --from=build /out/moonhub-runner-step /usr/local/bin/moonhub-runner-step
COPY LICENSE /usr/share/doc/moonhub/LICENSE
COPY vendor/yaml/LICENSE /usr/share/doc/moonhub/yaml-LICENSE
ENV PATH="/opt/moon/bin:/usr/local/bin:/usr/bin:/bin"
USER 10001:10001
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/moonhub", "runner"]

FROM runner AS runner-selfhost

FROM base AS provider
RUN groupadd --gid 10001 provider \
    && useradd --uid 10001 --gid provider --create-home provider \
    && mkdir -p /var/lib/moonhub/provider \
    && chown provider:provider /var/lib/moonhub/provider
COPY --from=build /src/_build/native/release/build/moonhub.exe /usr/local/bin/moonhub
COPY LICENSE /usr/share/doc/moonhub/LICENSE
COPY --chmod=755 deploy/provider-entrypoint.sh /usr/local/bin/moonhub-provider-entrypoint
WORKDIR /var/lib/moonhub/provider
ENTRYPOINT ["/usr/local/bin/moonhub-provider-entrypoint"]

FROM base AS runtime
RUN groupadd --gid 10001 git \
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
COPY --chmod=755 deploy/hooks/reference-transaction /usr/local/lib/moonhub/hooks/reference-transaction
ENV DB_PATH=/data/moonhub.db \
    MOONHUB_REPO_ROOT=/data/repos \
    MOONHUB_SSH_IMPORT_ROOT=/run/moonhub/ssh-import \
    MAIL_OUTBOX_DIR=/data/mail_outbox
WORKDIR /app
EXPOSE 8080 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/moonhub-entrypoint"]
CMD ["web"]
