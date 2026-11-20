# syntax=docker/dockerfile:1
# Headless opencode runner. Native opencode HTTP server + flat repo helper.
# Optional browser VS Code (off by default). No second harness, no web-search
# stack.
FROM node:26-bookworm-slim

ENV LANG=C.UTF-8 TZ=Europe/Athens \
     ENABLE_CODE_SERVER=false

RUN apt-get update \
     && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     ca-certificates nano curl git openssh-client python3 sudo supervisor util-linux \
     && rm -rf /var/lib/apt/lists/*

RUN userdel -r node 2>/dev/null; groupdel node 2>/dev/null; \
     useradd --create-home --uid 1000 --user-group --shell /bin/bash agent \
     && mkdir -p /run/supervisor /workspace \
     && chown agent:agent /run/supervisor /workspace \
     && echo 'agent ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/agent \
     && chmod 440 /etc/sudoers.d/agent

ARG OPENCODE_VERSION=1.19.6
RUN npm install -g --no-fund --no-audit "opencode-ai@${OPENCODE_VERSION}" \
     && opencode --version

# code-server stays in the image; ENABLE_CODE_SERVER decides if it runs.
# Digests copied from GitHub release asset metadata for v4.145.0.
ARG CODE_SERVER_VERSION=4.145.0
ARG CS_SHA_AMD64=771bf6038658034d7caf509fcc44af50f0b8bdac5e738177b6cf9c4181dd3382
ARG CS_SHA_ARM64=425d3bc5167c85dc070427d2aa93760083b02aec852ea9ce75c2906c99138f45
RUN CS_ARCH="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')" \
     && case "$CS_ARCH" in \
          amd64) CS_SHA="$CS_SHA_AMD64" ;; \
          arm64) CS_SHA="$CS_SHA_ARM64" ;; \
          *) echo "unsupported arch: $CS_ARCH" >&2; exit 1 ;; \
        esac \
     && curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${CS_ARCH}.tar.gz" \
     -o /tmp/cs.tgz \
     && echo "$CS_SHA  /tmp/cs.tgz" | sha256sum -c - \
     && mkdir -p /usr/local/lib/code-server \
     && tar -xzf /tmp/cs.tgz -C /usr/local/lib/code-server --strip-components=1 \
     && ln -sfn /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server \
     && rm -f /tmp/cs.tgz

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/fetch-repo /usr/local/bin/fetch-repo
COPY scripts/git-askpass /usr/local/bin/git-askpass
COPY scripts/opencode-config /usr/local/bin/opencode-config
COPY scripts/model-key-check /usr/local/bin/model-key-check
COPY scripts/opencode-gateway /usr/local/bin/opencode-gateway
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/fetch-repo \
      /usr/local/bin/git-askpass /usr/local/bin/opencode-config \
      /usr/local/bin/model-key-check \
      /usr/local/bin/opencode-gateway

EXPOSE 4096 8443
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
