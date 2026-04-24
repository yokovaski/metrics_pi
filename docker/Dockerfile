# Telegraf + smartmontools + nvme-cli on arm64 (Pi 5).
# Official telegraf image omits smartctl/nvme, so we add them here.
ARG TELEGRAF_VERSION=1.32
FROM telegraf:${TELEGRAF_VERSION}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      smartmontools \
      nvme-cli \
      libcap2-bin \
 && rm -rf /var/lib/apt/lists/* \
 && usermod -aG disk telegraf \
 && setcap cap_sys_rawio,cap_sys_admin+ep /usr/sbin/smartctl \
 && setcap cap_sys_rawio,cap_sys_admin+ep /usr/sbin/nvme

COPY smart_probe.sh /usr/local/bin/smart_probe.sh
RUN chmod +x /usr/local/bin/smart_probe.sh
