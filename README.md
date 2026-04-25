# metrics_pi

Pipeline: Raspberry Pi → Telegraf → MQTT → Home Assistant → InfluxDB → Grafana.

Three Pis push CPU, RAM, SoC temperature, and per-disk (NVMe + SATA)
temperature into Home Assistant as MQTT sensor entities. HA's InfluxDB
integration mirrors entity states into the InfluxDB addon. Grafana
addon reads InfluxDB for dashboards.

Full design: `/home/erwin/.claude/plans/i-have-3-raspberry-fuzzy-penguin.md`.

## Repo layout

```
docker-compose.yml              # run on each Pi: `docker compose up -d --build`
docker/Dockerfile               # telegraf + smartmontools + nvme-cli image
.env.example                    # copy to .env on each Pi, fill in HA_HOST + MQTT creds
telegraf/telegraf.conf          # bind-mounted into the container (read-only)
telegraf/sudoers.d_telegraf     # only needed for the legacy bare-metal apt install
scripts/setup.sh                # run on each Pi: one-shot onboarding (idempotent)
scripts/publish_discovery.sh    # invoked by setup.sh; re-run on fleet/disk changes
scripts/update.sh               # run on each Pi: git pull + restart container
ha/configuration.snippet.yaml   # merge into /config/configuration.yaml on HA
grafana/dashboards/             # export your Grafana dashboard JSON here
```

## Prerequisites

- Home Assistant OS with these addons installed and running:
  - Mosquitto broker
  - InfluxDB (v2 assumed; v1 works with minor edits)
  - Grafana
- Three Raspberry Pis (Pi 5 / arm64 verified) on a network reachable to
  HA on TCP 1883, running Raspberry Pi OS Bookworm or Trixie. `setup.sh`
  installs Docker and the host-side CLI tools (`smartmontools`,
  `nvme-cli`, `mosquitto-clients`) for you if they're missing.

## Step 1 — Home Assistant side

### 1a. Create MQTT user

HA UI → **Settings → People → Users → Add user**.
- Username: `telegraf`
- Untick admin
- Strong password (save it — you'll paste it into Telegraf config)

Mosquitto addon authenticates against HA users by default — no broker
config edit needed.

### 1b. Create InfluxDB bucket + token

InfluxDB addon UI:
- Create bucket `homeassistant`
- Create API token with write access to that bucket — copy it
- Note the Organization name/ID

### 1c. Merge HA config

Append the contents of `ha/configuration.snippet.yaml` to
`/config/configuration.yaml`. Add to `/config/secrets.yaml`:

```yaml
influxdb_token: <token from 1b>
influxdb_org: <org from 1b>
```

Create `/config/packages/` (empty is fine).

Restart Home Assistant. Check **Settings → System → Logs** — no InfluxDB
errors.

## Step 2 — Per Pi (repeat for each Pi)

Each Pi runs Telegraf in a Docker container built from
`docker/Dockerfile` (Telegraf upstream image + `smartmontools` +
`nvme-cli`). The official `telegraf` apt package was dropped from
Debian Trixie, so Docker is now the supported install path.

```bash
git clone <this-repo> ~/metrics_pi
cd ~/metrics_pi
bash scripts/setup.sh
```

`setup.sh` is idempotent — re-run it any time. It walks through:

1. **Prereqs** — verifies / installs Docker, `smartmontools`,
   `nvme-cli`, `mosquitto-clients`.
2. **`.env`** — prompts for `HA_HOST`, `MQTT_USER`, `MQTT_PASS` (or
   keeps existing values).
3. **MQTT probe** — pub/sub round-trip against the broker so wrong
   creds / unreachable host fail fast.
4. **Disk discovery** — runs `sudo smartctl --scan` and writes
   `docker-compose.override.yml` (gitignored) with the matching
   `/dev/...` passthrough. Tracked `docker-compose.yml` stays clean.
   If your fleet has disks other than `sda` + `nvme0`, the script
   warns you to also edit the `[[inputs.exec]]` blocks in
   `telegraf/telegraf.conf` (lines 34–72) to match — one block per
   disk.
5. **Container** — `docker compose up -d --build` (or restart / leave
   running on re-runs), then tails logs for MQTT connect.
6. **HA discovery** — invokes `scripts/publish_discovery.sh` to
   publish retained MQTT Discovery configs so HA auto-creates the
   sensor entities.

Later updates on each Pi:

```bash
bash scripts/update.sh
```

If you add or remove a disk later, re-run `bash scripts/setup.sh` —
it'll regenerate the override and re-publish discovery.

<details>
<summary>Manual fallback (skip <code>setup.sh</code>)</summary>

If you prefer to run each step by hand:

1. **Identify SMART devices:** `sudo smartctl --scan`. Record the
   device paths AND the `-d` type hint. Typical output:

   ```
   /dev/sda   -d sat   # /dev/sda [SAT], ATA device
   /dev/nvme0 -d nvme  # /dev/nvme0, NVMe device
   ```

   NVMe disks appear as the controller char device `/dev/nvme0` —
   the block device `/dev/nvme0n1` is for filesystem I/O only. Don't
   pass it to smartctl or Docker. USB-SATA bridges need `-d sat` or
   smartctl returns "Unknown USB bridge".

2. **Create `.env`:** `cp .env.example .env`, then edit `HA_HOST`,
   `MQTT_USER`, `MQTT_PASS`. `.env` is gitignored.

3. **Override device passthrough:** create `docker-compose.override.yml`
   (gitignored) listing the disks `smartctl --scan` reported on this
   Pi:

   ```yaml
   services:
     telegraf:
       devices:
         - /dev/nvme0:/dev/nvme0
         - /dev/sda:/dev/sda
   ```

   Compose merges it with `docker-compose.yml` automatically.

4. **Start:** `docker compose up -d --build && docker compose logs -f telegraf`.
   Expect MQTT connect and periodic `Wrote batch of N metrics`.

5. **Publish discovery:** `bash scripts/publish_discovery.sh`. Reads
   `.env` and auto-detects hostname + disks. Workstation mode for
   multiple Pis at once:

   ```bash
   FLEET="pi-a:nvme0,sda pi-b:nvme0,sda pi-c:nvme0" \
   bash scripts/publish_discovery.sh
   ```

   Messages are retained so HA recreates entities after restarts
   without re-running.

</details>

<details>
<summary>Bare-metal fallback (Bookworm only, no Docker)</summary>

If you prefer not to run Docker, the original apt-based install still
works on Bookworm: `sudo apt-get install -y telegraf smartmontools
nvme-cli`, copy `telegraf/telegraf.conf` to `/etc/telegraf/` (replacing
the `${HA_HOST}` / `${MQTT_USER}` / `${MQTT_PASS}` placeholders with
literal values), deploy `telegraf/sudoers.d_telegraf` via `sudo visudo
-f /etc/sudoers.d/telegraf`, set `use_sudo = true` in the smart input,
then `sudo systemctl enable --now telegraf`. Not available on Trixie.

</details>

## Step 3 — Verify

1. Watch raw MQTT from a workstation:
   ```bash
   mosquitto_sub -h <HA_HOST> -u telegraf -P '<pass>' -t 'metrics_pi/#' -v
   ```
   Expect JSON every 30 s from each Pi, plus SMART every 5 min.

2. HA UI → **Settings → Devices & Services → MQTT → Devices**. Should
   list each Pi as a device with sensors for CPU %, RAM %, CPU
   temperature, plus per-disk SMART temperature.

3. HA UI → **Developer Tools → States** → filter `pi_` — all sensors
   show numeric values, none say `unknown`.

4. InfluxDB addon UI → **Data Explorer** → bucket `homeassistant` →
   filter on your pi entity IDs. Points should accumulate.

## Step 4 — Grafana dashboard

Grafana addon → **Connections → Data sources → Add InfluxDB**:
- Query language: **Flux**
- URL: `http://a0d7b954-influxdb:8086`
- Organization / Token / Default bucket: values from Step 1b

Build a dashboard with panels for CPU %, RAM %, CPU temperature, disk
temperatures. Example Flux query (CPU % across fleet):

```flux
from(bucket: "homeassistant")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "%" and r.domain == "sensor"
                    and r.entity_id =~ /^pi_._cpu$/)
  |> filter(fn: (r) => r._field == "value")
  |> aggregateWindow(every: v.windowPeriod, fn: mean)
```

When done, export the dashboard JSON to `grafana/dashboards/pi_fleet.json`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Telegraf logs `connection refused` | HA IP wrong, port 1883 blocked by firewall, or Mosquitto addon down |
| Telegraf logs `not authorized` | Wrong MQTT user/password in `.env`, or user set as admin-only |
| Container exits immediately with `error gathering PID` or `no such device` | A `/dev/...` entry doesn't exist on this Pi — re-run `bash scripts/setup.sh` to regenerate `docker-compose.override.yml` |
| `smart_device` data shows `permission denied` in container logs | Container not `privileged: true`, or the device isn't passed through; check `docker-compose.override.yml` |
| No `smart_device` topic at all | `smartctl --scan` returned nothing on the Pi, or the disk isn't listed in the `[[inputs.exec]]` blocks of `telegraf/telegraf.conf` (defaults: `sda` + `nvme0`) |
| Hostname in MQTT topics is wrong | `network_mode: host` is required so Telegraf sees the Pi's real hostname; don't switch to bridge networking |
| HA shows entities but values are `unavailable` | State topic mismatch — check Telegraf is actually publishing to `metrics_pi/<host>/<plugin>`; run the `mosquitto_sub` command above |
| HA entities missing entirely | Discovery messages didn't land — re-run `publish_discovery.sh`; confirm MQTT integration in HA is configured with discovery prefix `homeassistant` (default) |
| InfluxDB has no data | `include.entity_globs` in `configuration.yaml` doesn't match actual entity IDs — check HA Developer Tools → States for real names, adjust globs |
| Grafana query returns empty | Wrong bucket/org/token on datasource, or `_measurement` filter wrong — in Flux, HA writes `_measurement` = unit string (e.g. `"%"`, `"°C"`) |

## Adding a fourth Pi

1. Clone the repo on the new Pi and run `bash scripts/setup.sh` —
   handles deps, `.env`, device override, container start, and
   discovery publish in one shot.
2. Add globs in HA `configuration.yaml` if the hostname prefix changes.

No changes needed in HA UI or Grafana — new entities flow through
automatically, and any dashboard panel using `entity_id =~ /^pi_/`
picks them up.
