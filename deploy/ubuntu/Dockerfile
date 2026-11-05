FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS node20
FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS action-dependencies
WORKDIR /opt/moonhub-actions
COPY runner/actions/package.json runner/actions/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# An Ubuntu selector requires actual Ubuntu userspace, never a relabeled Debian
# runner. Build with --platform linux/amd64 for the ubuntu-24.04 x64 capability.
FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b AS environment
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl git build-essential libssl-dev util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 runner \
    && useradd --uid 10001 --gid runner --create-home runner \
    && mkdir /workspace && chown runner:runner /workspace
COPY --from=action-dependencies /usr/local/bin/node /usr/local/bin/node
COPY --from=node20 /usr/local/bin/node /opt/actions/node20/bin/node
COPY --from=action-dependencies /opt/moonhub-actions/node_modules /usr/local/lib/moonhub/actions/node_modules
COPY runner/actions/*.mjs /usr/local/lib/moonhub/actions/
ENV PATH=/opt/moon/bin:/usr/local/bin:/usr/bin:/bin
LABEL io.moonhub.runner.environment="ubuntu-24.04"

# Compile only the standalone runner and its non-Web dependencies.
FROM environment AS native-build
ARG MOONBIT_VERSION=0.10.19+8e43a47fb-nightly
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
COPY provider/ provider/
COPY runner/ runner/
COPY pipeline/protocol/ pipeline/protocol/
COPY pipeline/actions/ pipeline/actions/
# The standalone source slice intentionally excludes database/Web test fixtures.
RUN node -e 'const fs=require("fs"),path=require("path"); function visit(dir){ for(const item of fs.readdirSync(dir,{withFileTypes:true})){ const file=path.join(dir,item.name); if(item.isDirectory()) visit(file); else if(item.name==="moon.pkg") fs.writeFileSync(file,fs.readFileSync(file,"utf8").replace(/import\s*\{[^}]*\}\s*for\s*"(?:wbtest|test)"/g,"")); }} for(const dir of ["cmd","provider","runner","pipeline"]) visit(dir);' \
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
