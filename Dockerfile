# syntax=docker/dockerfile:1
# Headless opencode runner. Native opencode HTTP server + tiny repo commissioning
# service. No UI, no second harness, no web search stack.
FROM node:24-bookworm-slim

ENV LANG=C.UTF-8 TZ=Europe/Athens \
     SSH_AUTH_SOCK=/tmp/ssh-agent/auth.sock

RUN apt-get update \
     && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     ca-certificates curl git jq openssh-client python3 sudo supervisor util-linux \
     && rm -rf /var/lib/apt/lists/*

RUN userdel -r node 2>/dev/null; groupdel node 2>/dev/null; \
     useradd --create-home --uid 1000 --user-group --shell /bin/bash agent \
     && mkdir -p /tmp/ssh-agent /run/supervisor /workspace \
     && chown agent:agent /tmp/ssh-agent /run/supervisor /workspace \
     && echo 'agent ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/agent \
     && chmod 440 /etc/sudoers.d/agent

ARG OPENCODE_VERSION=1.19.6
RUN npm install -g --no-fund --no-audit "opencode-ai@${OPENCODE_VERSION}" \
     && opencode --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY provisioner.py /usr/local/bin/provisioner.py
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/provisioner.py

EXPOSE 4096 8300
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
