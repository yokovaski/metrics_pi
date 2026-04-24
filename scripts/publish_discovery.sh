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
  # shellcheck disable=SC2206
  FLEET_ARR=(${FLEET})
fi

pub() {
  local topic="$1" payload="$2"
  mosquitto_pub -h "$HA_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -r -t "$topic" -m "$payload"
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
  done

  echo "published discovery for ${h} (disks: ${disks})"
done
