#!/bin/sh
# SMART probe for USB-SATA disks called by telegraf inputs.exec.
#
# Behavior:
#   * Issues a 1 MiB direct read to wake the drive before smartctl runs.
#   * Calls smartctl --json and emits JSON on stdout on success.
#   * Retries up to 3 times because spun-down disks behind USB bridges
#     occasionally fail the first IDENTIFY (exit bit 1 set).
#   * Treats exit codes where only bit 2 (SMART checksum warning) or
#     bit 0 (command-line) are set as fatal — everything higher (bits
#     3–7) is informational and we still emit the JSON to telegraf.
#
# Debug output goes to /tmp/smart_probe.log inside the container.

set -u

DEVICE="${1:-/dev/sda}"
TYPE="${2:-sat}"
# Optional active-hours window in local time. With both set, the script
# only probes when current hour is in [START, END). Outside the window it
# emits "{}" so json_v2 produces no fields and no MQTT metric is written —
# letting drives that idle (USB-SATA HDDs) actually spin down overnight.
# Container must mount /etc/localtime for this to use Pi-local time.
WINDOW_START="${3:-}"
WINDOW_END="${4:-}"
LOG=/tmp/smart_probe.log

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

log "run device=$DEVICE type=$TYPE window=${WINDOW_START:-always}-${WINDOW_END:-always}"

if [ -n "$WINDOW_START" ] && [ -n "$WINDOW_END" ]; then
  hour=$(date +%H)
  hour=${hour#0}
  : "${hour:=0}"
  if [ "$hour" -lt "$WINDOW_START" ] || [ "$hour" -ge "$WINDOW_END" ]; then
    log "outside window; skipping probe"
    printf '{}'
    exit 0
  fi
fi

# Pre-wake: blocks until the drive finishes spin-up.
dd if="$DEVICE" of=/dev/null bs=1M count=1 iflag=direct 2>>"$LOG" || log "dd warn rc=$?"

for attempt in 1 2 3; do
  out=$(/usr/sbin/smartctl -A -H -i -n never -d "$TYPE" "$DEVICE" --json 2>>"$LOG")
  rc=$?
  # bits: 0=cmdline, 1=open/identify, 2=SMART cmd failed (e.g. bad checksum)
  # Accept rc if JSON came through and only "soft" bits are set (≥4).
  if [ -n "$out" ] && [ $((rc & 3)) -eq 0 ]; then
    printf '%s' "$out"
    log "ok attempt=$attempt rc=$rc"
    exit 0
  fi
  log "retry attempt=$attempt rc=$rc out_len=${#out}"
  sleep 5
done

log "giving up rc=$rc"
exit 2
