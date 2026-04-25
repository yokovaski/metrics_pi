#!/usr/bin/env bash
# Publish Home Assistant MQTT Discovery configs for this Pi.
#
# Run on each Pi. Auto-detects hostname and SMART devices via `smartctl --scan`.
#
# Usage (per-Pi, auto-detect, reads .env in repo root):
#   bash scripts/publish_discovery.sh
#
# Env vars can also be passed directly or via a different file:
#   ENV_FILE=/path/to/.env bash scripts/publish_discovery.sh
#   HA_HOST=... MQTT_PASS=... bash scripts/publish_discovery.sh
#
# Workstation mode (publish for multiple hosts at once):
#   FLEET="pi-a:nvme0,sda pi-b:nvme0,sda pi-c:nvme0" bash scripts/publish_discovery.sh
#
# Requires `mosquitto_clients` (mosquitto_pub) and — in auto-detect mode —
# `smartmontools`. Messages are retained, so HA recreates entities on restart
# and you only need to re-run when the fleet composition changes.

set -euo pipefail

# Non-login shells (e.g. `ssh host 'bash script.sh'`) don't include sbin
# paths where smartctl/nvme typically live. Extend PATH so `command -v`
# and sudo both resolve them.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH}"

# Load .env from repo root if present (same file docker compose reads).
# Existing env vars take precedence — the file only fills in what's unset.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

HA_HOST="${HA_HOST:?set HA_HOST in .env or environment}"
MQTT_USER="${MQTT_USER:-telegraf}"
MQTT_PASS="${MQTT_PASS:?set MQTT_PASS in .env or environment}"
MQTT_PORT="${MQTT_PORT:-1883}"

if [[ -z "${FLEET:-}" ]]; then
  LOCAL_MODE=true
  h=$(hostname)
  if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not found — install smartmontools or set FLEET explicitly" >&2
    exit 1
  fi
  disks=$(sudo smartctl --scan \
    | awk 'NF && $1 ~ /^\/dev\// { sub(/^\/dev\//,"",$1); print $1 }' \
    | paste -sd,)
  if [[ -z "$disks" ]]; then
    echo "smartctl --scan returned no devices on ${h} — aborting" >&2
    exit 1
  fi
  FLEET_ARR=("${h}:${disks}")
else
  LOCAL_MODE=false
  # shellcheck disable=SC2206
  FLEET_ARR=(${FLEET})
fi

# nvme0 (smartctl controller name) -> nvme0n1 (block device for filesystem)
# sda                              -> sda
disk_block_dev() {
  case "$1" in
    nvme*) printf '/dev/%sn1' "$1" ;;
    *)     printf '/dev/%s' "$1" ;;
  esac
}

# Echoes "<partition_dev>\t<mountpoint>" for the primary mounted partition
# of the disk (prefers "/", then first non-swap mount). Returns 1 if none.
# Only meaningful in LOCAL_MODE where we can inspect the host's lsblk.
disk_primary_mount() {
  local block; block=$(disk_block_dev "$1")
  [[ -b "$block" ]] || return 1
  local rows
  rows=$(lsblk -nrpo NAME,MOUNTPOINTS "$block" 2>/dev/null \
    | awk '$2 != "" && $2 != "[SWAP]" { sub("^/dev/","",$1); print $1"\t"$2 }')
  [[ -z "$rows" ]] && return 1
  local root_line
  root_line=$(printf '%s\n' "$rows" | awk -F'\t' '$2=="/" {print; exit}')
  if [[ -n "$root_line" ]]; then
    printf '%s\n' "$root_line"
  else
    printf '%s\n' "$rows" | head -n1
  fi
}

pub() {
  local topic="$1" payload="$2"
  mosquitto_pub -h "$HA_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -r -t "$topic" -m "$payload"
}

# Publish an empty retained payload to drop a previously retained discovery
# config — HA removes the entity and the broker drops the retained message.
pub_clear() {
  local topic="$1"
  mosquitto_pub -h "$HA_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -r -n -t "$topic"
}

for entry in "${FLEET_ARR[@]}"; do
  h="${entry%%:*}"
  disks="${entry#*:}"
  dev=$(printf '{"identifiers":["%s"],"name":"%s","model":"Raspberry Pi","manufacturer":"Raspberry Pi Foundation"}' "$h" "$h")

  pub "homeassistant/sensor/${h}/cpu/config" \
"{\"name\":\"${h} CPU\",\"unique_id\":\"${h}_cpu\",\
\"state_topic\":\"metrics_pi/${h}/cpu\",\
\"value_template\":\"{{ (100 - value_json.fields.usage_idle) | round(1) }}\",\
\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\
\"device\":${dev}}"

  pub "homeassistant/sensor/${h}/ram/config" \
"{\"name\":\"${h} RAM\",\"unique_id\":\"${h}_ram\",\
\"state_topic\":\"metrics_pi/${h}/mem\",\
\"value_template\":\"{{ value_json.fields.used_percent | round(1) }}\",\
\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\
\"device\":${dev}}"

  pub "homeassistant/sensor/${h}/temp_cpu/config" \
"{\"name\":\"${h} CPU temperature\",\"unique_id\":\"${h}_temp_cpu\",\
\"state_topic\":\"metrics_pi/${h}/temp\",\
\"value_template\":\"{% if value_json.tags.sensor == 'cpu_thermal' %}{{ value_json.fields.temp }}{% else %}{{ this.state }}{% endif %}\",\
\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\
\"state_class\":\"measurement\",\"device\":${dev}}"

  IFS=',' read -ra DISKS <<< "$disks"
  for d in "${DISKS[@]}"; do
    pub "homeassistant/sensor/${h}/temp_${d}/config" \
"{\"name\":\"${h} ${d} temperature\",\"unique_id\":\"${h}_temp_${d}\",\
\"state_topic\":\"metrics_pi/${h}/smart_device\",\
\"value_template\":\"{% if value_json.tags.device == '${d}' %}{{ value_json.fields.temp_c }}{% else %}{{ this.state }}{% endif %}\",\
\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\
\"state_class\":\"measurement\",\"device\":${dev}}"

    # Disk free-bytes sensor: only in local mode (lsblk runs against the
    # local host's block devices). Workstation FLEET mode skips this — re-run
    # `bash scripts/publish_discovery.sh` on each Pi to publish them.
    # device_class=data_size + unit B lets HA auto-render as GB/TB in the UI.
    if $LOCAL_MODE; then
      # Drop the prior used-% sensor if it was previously published.
      pub_clear "homeassistant/sensor/${h}/disk_${d}_used/config"
      if mp_info=$(disk_primary_mount "$d"); then
        dev_tag="${mp_info%$'\t'*}"
        pub "homeassistant/sensor/${h}/disk_${d}_free/config" \
"{\"name\":\"${h} ${d} free space\",\"unique_id\":\"${h}_disk_${d}_free\",\
\"state_topic\":\"metrics_pi/${h}/disk\",\
\"value_template\":\"{% if value_json.tags.device == '${dev_tag}' %}{{ value_json.fields.free }}{% else %}{{ this.state }}{% endif %}\",\
\"device_class\":\"data_size\",\"unit_of_measurement\":\"B\",\
\"suggested_unit_of_measurement\":\"GB\",\"state_class\":\"measurement\",\
\"icon\":\"mdi:harddisk\",\"device\":${dev}}"
      fi
    fi
  done

  echo "published discovery for ${h} (disks: ${disks})"
done
