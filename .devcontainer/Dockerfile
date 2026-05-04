# EPL Engagement Platform devcontainer
#
# Replaces the originally-planned GL.iNet Beryl AX (GL-MT3000) hardware as the
# per-student "primary engagement platform." Same OpenWrt 23.05.3 baseline as
# the GL.iNet Mango drop device, just unconstrained on flash/RAM so the full
# engagement-stack (tailscale, cloudflared, python, etc.) lives here.
#
# Native CPU differs from Mango (x86_64 vs ramips/mt76x8 MIPS). UCI, opkg,
# /etc/init.d, and procd are identical — the OS is the OS.

FROM openwrt/rootfs:x86-64-23.05.3

ARG OPENWRT_VERSION=23.05.3
LABEL org.errantpacket.epl.role="engagement-platform"
LABEL org.errantpacket.epl.openwrt-version="${OPENWRT_VERSION}"
LABEL org.errantpacket.epl.replaces="glinet_gl-mt3000"

# OpenWrt rootfs ships without /var/lock /var/run as real dirs; opkg needs them
RUN mkdir -p /var/lock /var/run /var/log /var/lib/tailscale /etc/cloudflared

# Install the engagement-stack. We split into two opkg invocations so a
# transient feed failure doesn't poison the whole layer.
RUN opkg update \
 && opkg install \
      ca-bundle ca-certificates curl wget-ssl jq jsonfilter \
      bash openssh-client git \
      python3 python3-pip python3-cryptography \
      tcpdump nmap socat netcat-openbsd \
      iperf3 htop \
      wireguard-tools \
 && rm -rf /tmp/opkg-lists/*

RUN opkg update \
 && opkg install \
      tailscale \
      luci luci-mod-admin-full luci-theme-bootstrap uhttpd \
      nginx-ssl \
 && rm -rf /tmp/opkg-lists/*

# cloudflared isn't in the OpenWrt feeds at 23.05.3; pull the upstream binary
# pinned to a workshop-known SHA. Update CLOUDFLARED_VERSION + CLOUDFLARED_SHA
# in lockstep when refreshing the workshop materials.
ARG CLOUDFLARED_VERSION=2024.10.0
ARG CLOUDFLARED_SHA=PLACEHOLDER_PIN_AT_BUILD_TIME
RUN curl -fsSL -o /usr/sbin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
 && chmod +x /usr/sbin/cloudflared \
 && /usr/sbin/cloudflared --version

# Workshop convenience: wrangler for Workers/D1/KV/R2 deploys
RUN opkg install nodejs npm \
 && npm install -g wrangler@4 \
 && rm -rf /root/.npm /tmp/npm-* /tmp/opkg-lists/*

ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WORKDIR /workspaces/engagement-platform-labs

CMD ["sh", "-c", "echo '[EPL] devcontainer ready; PID 1 sleeping. Use VS Code terminal or `docker exec`.'; tail -f /dev/null"]
