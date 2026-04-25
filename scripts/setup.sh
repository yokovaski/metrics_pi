#!/usr/bin/env bash
# Pi-side onboarding for metrics_pi. Run on each new Pi:
#   bash scripts/setup.sh
#
# Idempotent — re-running detects existing state and asks before overwriting.
# Covers: prereq install, .env, MQTT probe, disk passthrough override,
# container start, HA discovery publish. HA-side steps (MQTT user, InfluxDB
# bucket, configuration.yaml) stay manual — see README §1.

set -euo pipefail

# Non-login shells (e.g. `ssh host 'bash setup.sh'`) miss sbin paths where
# smartctl/nvme live. Match the same fix used in publish_discovery.sh.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"
OVERRIDE_FILE="${REPO_ROOT}/docker-compose.override.yml"

# ---------------- helpers ----------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '  %sx%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# ask "prompt" "default" -> echoes user answer (or default if empty input)
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [${default}]: " reply || true
    printf '%s' "${reply:-$default}"
  else
    read -rp "  ${prompt}: " reply || true
    printf '%s' "$reply"
  fi
}

# ask_secret "prompt" -> echoes user answer, no echo to terminal
ask_secret() {
  local prompt="$1" reply
  read -rsp "  ${prompt}: " reply || true
  printf '\n' >&2
  printf '%s' "$reply"
}

# ask_choice "prompt" "default" "opt1" "opt2" ... -> echoes selected option
# Prompt + menu go to stderr so callers can do: choice=$(ask_choice ...)
ask_choice() {
  local prompt="$1" default="$2"; shift 2
  local opts=("$@") reply
  printf '  %s\n' "$prompt" >&2
  local i=1
  for o in "${opts[@]}"; do
    if [[ "$o" == "$default" ]]; then
      printf '    %d) %s (default)\n' "$i" "$o" >&2
    else
      printf '    %d) %s\n' "$i" "$o" >&2
    fi
    ((i++))
  done
  read -rp "  choice [1-${#opts[@]}]: " reply || true
  if [[ -z "$reply" ]]; then
    printf '%s' "$default"; return
  fi
  if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#opts[@]} )); then
    printf '%s' "${opts[$((reply-1))]}"
  else
    printf '%s' "$default"
  fi
}

confirm() {
  local prompt="$1" default="${2:-n}" reply suffix
  if [[ "$default" == "y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  read -rp "  ${prompt} ${suffix}: " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

apt_install() {
  local pkg="$1"
  if ! confirm "Install ${pkg} via apt?" "y"; then
    err "${pkg} required — aborting"
    exit 1
  fi
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends "$pkg"
}

# ---------------- preflight ----------------

step "Preflight"

if [[ "${EUID}" -eq 0 ]]; then
  err "Don't run as root. Run as the user that owns ~/metrics_pi (will sudo as needed)."
  exit 1
fi

case "$(uname -s)" in
  Linux) ok "Linux host" ;;
  *)     err "This script targets Linux Pis only — got $(uname -s)"; exit 1 ;;
esac

cd "$REPO_ROOT"
ok "repo root: $REPO_ROOT"

# ---------------- prereqs ----------------

step "Prerequisites"

# Docker + compose plugin.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "docker + compose plugin present ($(docker --version | awk '{print $3}' | tr -d ,))"
else
  warn "docker / compose plugin missing"
  if confirm "Install Docker via get.docker.com convenience script?" "y"; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group — log out/in (or run: newgrp docker) before continuing"
    err "Re-run this script after re-login"
    exit 1
  else
    err "docker required — aborting"
    exit 1
  fi
fi

# User in docker group?
if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  ok "user '$USER' in docker group"
else
  warn "user '$USER' not in docker group — run: sudo usermod -aG docker $USER && newgrp docker"
fi

# CLI tools used at runtime (smart_probe.sh runs inside container, but
# smartctl --scan and mosquitto_pub run on the host for setup + discovery).
for pkg_bin in "smartmontools:smartctl" "nvme-cli:nvme" "mosquitto-clients:mosquitto_pub"; do
  pkg="${pkg_bin%%:*}"; bin="${pkg_bin##*:}"
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$pkg present ($bin)"
  else
    warn "$pkg missing"
    apt_install "$pkg"
    ok "$pkg installed"
  fi
done

# ---------------- .env ----------------

step ".env credentials"

if [[ ! -f "$ENV_EXAMPLE" ]]; then
  err ".env.example missing — repo state broken"
  exit 1
fi

write_env() {
  local ha_host="$1" mqtt_user="$2" mqtt_pass="$3"
  cat >"$ENV_FILE" <<EOF
HA_HOST=${ha_host}
MQTT_USER=${mqtt_user}
MQTT_PASS=${mqtt_pass}
EOF
  chmod 600 "$ENV_FILE"
}

reenter_env=true
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  ( set -a; source "$ENV_FILE"; set +a
    printf '  current values:\n'
    printf '    HA_HOST=%s\n' "${HA_HOST:-<unset>}"
    printf '    MQTT_USER=%s\n' "${MQTT_USER:-<unset>}"
    printf '    MQTT_PASS=%s\n' "$([[ -n "${MQTT_PASS:-}" ]] && printf '***' || printf '<unset>')"
  )
  if confirm "Keep existing .env?" "y"; then
    reenter_env=false
    ok "kept existing .env"
  fi
fi

if $reenter_env; then
  HA_HOST_IN=$(ask "HA_HOST (broker hostname or IP)" "${HA_HOST:-homeassistant.local}")
  MQTT_USER_IN=$(ask "MQTT_USER" "${MQTT_USER:-telegraf}")
  MQTT_PASS_IN=$(ask_secret "MQTT_PASS")
  if [[ -z "$MQTT_PASS_IN" ]]; then
    err "MQTT_PASS cannot be empty"
    exit 1
  fi
  write_env "$HA_HOST_IN" "$MQTT_USER_IN" "$MQTT_PASS_IN"
  ok "wrote $ENV_FILE (mode 600)"
fi

# Source for downstream steps.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------- MQTT probe ----------------

step "MQTT broker probe"

probe_topic="metrics_pi/_setup_probe/$(hostname)"
probe_payload="setup-$(date +%s)"

if mosquitto_pub -h "$HA_HOST" -p 1883 \
     -u "$MQTT_USER" -P "$MQTT_PASS" \
     -t "$probe_topic" -m "$probe_payload" -q 0 -r 2>/tmp/mqtt_probe.err; then
  # Round-trip with a 5s timeout. -r above means broker retains the message
  # so a subscriber starting after pub still sees it.
  if got=$(mosquitto_sub -h "$HA_HOST" -p 1883 \
             -u "$MQTT_USER" -P "$MQTT_PASS" \
             -t "$probe_topic" -C 1 -W 5 2>/dev/null); then
    if [[ "$got" == "$probe_payload" ]]; then
      ok "publish + subscribe round-trip OK ($HA_HOST:1883 as $MQTT_USER)"
    else
      warn "round-trip returned unexpected payload: $got"
    fi
  else
    warn "subscribe timed out — pub worked, sub did not. Broker may not retain non-retained messages."
  fi
  # Cleanup retained probe.
  mosquitto_pub -h "$HA_HOST" -p 1883 -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$probe_topic" -n -r >/dev/null 2>&1 || true
else
  err "MQTT publish failed:"
  sed 's/^/    /' /tmp/mqtt_probe.err >&2 || true
  cat <<EOF >&2

  Common causes:
    - HA_HOST wrong or unreachable (try: ping $HA_HOST)
    - Mosquitto addon stopped (HA → Settings → Add-ons → Mosquitto broker)
    - MQTT user not created / wrong password (HA → Settings → People → Users)
    - Port 1883 firewalled

EOF
  exit 1
fi

# ---------------- disk passthrough override ----------------

step "Disk discovery"

scan_out=$(sudo smartctl --scan 2>/dev/null || true)
if [[ -z "$scan_out" ]]; then
  err "smartctl --scan returned nothing — no SMART devices detected"
  exit 1
fi

# Parse: keep first column path, normalize NVMe to controller (/dev/nvme0).
# `smartctl --scan` typically prints lines like:
#   /dev/sda -d sat # /dev/sda [SAT], ATA device
#   /dev/nvme0 -d nvme # /dev/nvme0, NVMe device
mapfile -t devices < <(printf '%s\n' "$scan_out" \
  | awk 'NF && $1 ~ /^\/dev\// { print $1 }' \
  | sed -E 's#(/dev/nvme[0-9]+)n[0-9]+#\1#' \
  | sort -u)

if [[ ${#devices[@]} -eq 0 ]]; then
  err "could not parse smartctl --scan output:"
  printf '%s\n' "$scan_out" | sed 's/^/    /' >&2
  exit 1
fi

printf '  detected:\n'
for d in "${devices[@]}"; do printf '    %s\n' "$d"; done

if ! confirm "Use these devices in docker-compose.override.yml?" "y"; then
  err "aborting — edit docker-compose.yml manually if your layout differs"
  exit 1
fi

# Warn if telegraf.conf has hardcoded inputs.exec blocks for devices that
# aren't in our scan, or vice versa. Current shipped config covers sda + nvme0.
expected=("/dev/sda" "/dev/nvme0")
mismatch=false
for d in "${devices[@]}"; do
  if ! printf '%s\n' "${expected[@]}" | grep -qx "$d"; then mismatch=true; break; fi
done
for d in "${expected[@]}"; do
  if ! printf '%s\n' "${devices[@]}" | grep -qx "$d"; then mismatch=true; break; fi
done
if $mismatch; then
  warn "telegraf/telegraf.conf inputs.exec blocks are hardcoded for /dev/sda + /dev/nvme0."
  warn "Your fleet differs — edit telegraf.conf lines 34-72 to match (one [[inputs.exec]] block per disk)."
fi

write_override=true
if [[ -f "$OVERRIDE_FILE" ]]; then
  printf '  current %s:\n' "$OVERRIDE_FILE"
  sed 's/^/    /' "$OVERRIDE_FILE"
  if confirm "Keep existing override?" "y"; then
    write_override=false
    ok "kept existing override"
  fi
fi

if $write_override; then
  {
    printf '# Generated by scripts/setup.sh — gitignored.\n'
    printf '# Per-Pi /dev passthrough. Regenerate by re-running setup.sh.\n'
    printf 'services:\n'
    printf '  telegraf:\n'
    printf '    devices:\n'
    for d in "${devices[@]}"; do
      printf '      - %s:%s\n' "$d" "$d"
    done
  } >"$OVERRIDE_FILE"
  ok "wrote $OVERRIDE_FILE"
fi

# ---------------- container ----------------

step "Telegraf container"

container_state=""
if docker inspect -f '{{.State.Status}}' telegraf >/dev/null 2>&1; then
  container_state=$(docker inspect -f '{{.State.Status}}' telegraf)
fi

action="rebuild"
if [[ "$container_state" == "running" ]]; then
  ok "container 'telegraf' is running"
  action=$(ask_choice "Container action:" "leave" "leave" "restart" "rebuild")
elif [[ -n "$container_state" ]]; then
  warn "container 'telegraf' state: $container_state"
  action=$(ask_choice "Container action:" "rebuild" "start" "rebuild")
else
  ok "no existing container — will build + start"
  action="rebuild"
fi

case "$action" in
  leave)   ok "leaving container as-is" ;;
  start)   docker compose up -d ;;
  restart) docker compose restart telegraf ;;
  rebuild) docker compose up -d --build ;;
esac

if [[ "$action" != "leave" ]]; then
  printf '  waiting up to 20s for MQTT connect...\n'
  deadline=$(( $(date +%s) + 20 ))
  connected=false
  while (( $(date +%s) < deadline )); do
    if docker compose logs --no-color --since 30s telegraf 2>/dev/null \
         | grep -qE 'Connected to .*://|Wrote batch of'; then
      connected=true
      break
    fi
    sleep 2
  done
  if $connected; then
    ok "telegraf connected to broker / wrote first batch"
  else
    warn "no MQTT activity in logs yet — check manually: docker compose logs -f telegraf"
    docker compose logs --no-color --tail 20 telegraf | sed 's/^/    /' || true
  fi
fi

# ---------------- HA discovery ----------------

step "HA discovery configs"

host=$(hostname)
discovery_topic="homeassistant/sensor/${host}/+/config"

publish_now=true
if existing=$(timeout 4 mosquitto_sub -h "$HA_HOST" -p 1883 \
                -u "$MQTT_USER" -P "$MQTT_PASS" \
                -t "$discovery_topic" -C 1 -W 3 2>/dev/null); then
  if [[ -n "$existing" ]]; then
    ok "discovery configs already retained for ${host}"
    if ! confirm "Re-publish discovery configs?" "n"; then
      publish_now=false
    fi
  fi
fi

if $publish_now; then
  bash "${SCRIPT_DIR}/publish_discovery.sh"
fi

# ---------------- summary ----------------

step "Summary"

container_state_final="(none)"
if docker inspect -f '{{.State.Status}}' telegraf >/dev/null 2>&1; then
  container_state_final=$(docker inspect -f '{{.State.Status}}' telegraf)
fi

cat <<EOF
  hostname:       ${host}
  HA broker:      ${HA_HOST}:1883 as ${MQTT_USER}
  disks:          ${devices[*]}
  .env:           ${ENV_FILE}
  override:       ${OVERRIDE_FILE}
  container:      ${container_state_final}

${C_BOLD}Next steps:${C_RESET}
  1. HA UI → Settings → Devices & Services → MQTT → Devices
     Confirm '${host}' appears with CPU/RAM/temp/disk sensors.
  2. Tail live data:
       mosquitto_sub -h ${HA_HOST} -u ${MQTT_USER} -P '<pass>' -t 'metrics_pi/#' -v
  3. To update later: bash scripts/update.sh
EOF

ok "setup complete"
