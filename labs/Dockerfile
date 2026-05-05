FROM openwrt/imagebuilder:ramips-mt76x8-23.05.3

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    file rsync && rm -rf /var/lib/apt/lists/*
USER buildbot

# Upstream openwrt/imagebuilder unpacks ImageBuilder at /builder (verified
# 2026-05-04 against ramips-mt76x8-23.05.3). Earlier revisions of this
# Dockerfile pointed at /home/buildbot/openwrt-imagebuilder which only
# created an empty directory; the upstream image has no /home/buildbot.
WORKDIR /builder
