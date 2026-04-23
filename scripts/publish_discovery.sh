#!/usr/bin/env bash
# Publish Home Assistant MQTT Discovery configs for the Pi fleet.
#
# Usage:
#   HA_HOST=homeassistant.local MQTT_PASS='...' bash scripts/publish_discovery.sh
#
# Requires `mosquitto_clients` (mosquitto_pub) on the machine you run it from.
# Messages are retained, so HA recreates the entities on every restart and you
# only need to re-run this script when the fleet composition changes.

set -euo pipefail

HA_HOST="${HA_HOST:?set HA_HOST to your Home Assistant IP or hostname}"
MQTT_USER="${MQTT_USER:-telegraf}"
MQTT_PASS="${MQTT_PASS:?set MQTT_PASS to the telegraf MQTT user password}"
MQTT_PORT="${MQTT_PORT:-1883}"

# host:disk1,disk2,...
# Adjust to match actual SMART device short-names from `sudo smartctl --scan`
# on each Pi. Example below: all three have nvme0, two also have sda.
FLEET=(
  "pi-a:nvme0,sda"
  "pi-b:nvme0,sda"
  "pi-c:nvme0"
)

pub() {
  local topic="$1" payload="$2"
  mosquitto_pub -h "$HA_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -r -t "$topic" -m "$payload"
}

for entry in "${FLEET[@]}"; do
  h="${entry%%:*}"
  disks="${entry#*:}"
  dev=$(printf '{"identifiers":["%s"],"name":"%s","model":"Raspberry Pi","manufacturer":"Raspberry Pi Foundation"}' "$h" "$h")

  pub "homeassistant/sensor/${h}/cpu/config" \
"{\"name\":\"${h} CPU\",\"unique_id\":\"${h}_cpu\",\
\"state_topic\":\"metrics_pi/${h}/cpu\",\
\"value_template\":\"{{ (100 - value_json.usage_idle) | round(1) }}\",\
\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\
\"device\":${dev}}"

  pub "homeassistant/sensor/${h}/ram/config" \
"{\"name\":\"${h} RAM\",\"unique_id\":\"${h}_ram\",\
\"state_topic\":\"metrics_pi/${h}/mem\",\
\"value_template\":\"{{ value_json.used_percent | round(1) }}\",\
\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\
\"device\":${dev}}"

  pub "homeassistant/sensor/${h}/temp_cpu/config" \
"{\"name\":\"${h} CPU temperature\",\"unique_id\":\"${h}_temp_cpu\",\
\"state_topic\":\"metrics_pi/${h}/temperature\",\
\"value_template\":\"{% if value_json.sensor == 'cpu_thermal' %}{{ value_json.temp }}{% endif %}\",\
\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\
\"state_class\":\"measurement\",\"device\":${dev}}"

  IFS=',' read -ra DISKS <<< "$disks"
  for d in "${DISKS[@]}"; do
    pub "homeassistant/sensor/${h}/temp_${d}/config" \
"{\"name\":\"${h} ${d} temperature\",\"unique_id\":\"${h}_temp_${d}\",\
\"state_topic\":\"metrics_pi/${h}/smart_device\",\
\"value_template\":\"{% if value_json.device == '${d}' %}{{ value_json.temp_c }}{% endif %}\",\
\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\
\"state_class\":\"measurement\",\"device\":${dev}}"
  done

  echo "published discovery for ${h} (disks: ${disks})"
done
