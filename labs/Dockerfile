FROM openwrt/imagebuilder:ramips-mt76x8-23.05.3

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    file rsync && rm -rf /var/lib/apt/lists/*
USER buildbot

WORKDIR /home/buildbot/openwrt-imagebuilder
