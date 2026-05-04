# EPL Engagement Platform devcontainer — Debian operator console
#
# Two-tier architecture: this OUTER container is a Debian-based operator
# console (vscode-server runs natively on glibc; works in Codespaces, local
# Dev Containers, and DevPod/podman). The OpenWrt rootfs lives on as a
# SIBLING container students launch via docker-in-docker — see Lab 01 Step 4
# and post-create.sh. The Mango↔OpenWrt-rootfs comparison in Lab 01 Step 5
# uses the sibling, so the "OS is the OS" pedagogy is preserved.
#
# Outer (this image): Debian bookworm + tailscale + cloudflared + wrangler@4
#                     + python + the rest of the engagement-stack.
# Sibling (Lab 01):   openwrt/rootfs:x86-64-23.05.3, launched via DinD.

FROM mcr.microsoft.com/devcontainers/base:bookworm

ARG OPENWRT_VERSION=23.05.3
LABEL org.errantpacket.epl.role="engagement-platform-operator-console"
LABEL org.errantpacket.epl.openwrt-version="${OPENWRT_VERSION}"
LABEL org.errantpacket.epl.replaces="glinet_gl-mt3000"

# Engagement-stack: networking + CLI tooling. apt is split into focused
# invocations so a transient mirror flake localizes the failure.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl wget jq ca-certificates gnupg lsb-release \
      python3 python3-pip python3-cryptography python3-venv \
      tcpdump nmap socat netcat-openbsd \
      iperf3 htop \
      wireguard-tools iproute2 iputils-ping dnsutils \
      openssh-client git make \
 && rm -rf /var/lib/apt/lists/*

# Node 20 (NodeSource — wrangler@4 requires Node >= 20)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g wrangler@4 \
 && rm -rf /root/.npm /tmp/npm-*

# Tailscale (apt repo). Userspace networking is configured per-environment in
# post-create.sh; the binary is the same.
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        > /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tailscale \
 && rm -rf /var/lib/apt/lists/*

# cloudflared (Cloudflare apt repo)
RUN curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        > /usr/share/keyrings/cloudflare-main.gpg \
 && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' \
        > /etc/apt/sources.list.d/cloudflared.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloudflared \
 && rm -rf /var/lib/apt/lists/* \
 && cloudflared --version

# State volumes (mounted in devcontainer.json)
RUN mkdir -p /var/lib/tailscale /etc/cloudflared

# Convenience: shell helper for entering the OpenWrt rootfs sibling.
RUN printf '#!/bin/sh\nexec docker exec -it ep-devcontainer /bin/sh "$@"\n' \
        > /usr/local/bin/openwrt-shell \
 && chmod +x /usr/local/bin/openwrt-shell

WORKDIR /workspaces
