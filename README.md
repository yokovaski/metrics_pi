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
scripts/publish_discovery.sh    # run once from a workstation to register HA entities
ha/configuration.snippet.yaml   # merge into /config/configuration.yaml on HA
grafana/dashboards/             # export your Grafana dashboard JSON here
```

## Prerequisites

- Home Assistant OS with these addons installed and running:
  - Mosquitto broker
  - InfluxDB (v2 assumed; v1 works with minor edits)
  - Grafana
- Three Raspberry Pis (Pi 5 / arm64 verified) on a network reachable to
  HA on TCP 1883, running Raspberry Pi OS Bookworm or Trixie, with
  Docker Engine and Compose v2 installed (`curl -fsSL https://get.docker.com | sh`,
  then `sudo usermod -aG docker $USER` and re-login).
- `mosquitto-clients` and `smartmontools` on the machine you'll run the
  discovery script from (`sudo apt-get install -y mosquitto-clients
  smartmontools`). `smartmontools` is used by the script to auto-detect
  SMART devices via `smartctl --scan`; skip it only if you set `FLEET`
  explicitly.

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

## Step 2 — Per Pi (repeat for pi-a, pi-b, pi-c)

Each Pi runs Telegraf in a Docker container built from
`docker/Dockerfile` (Telegraf upstream image + `smartmontools` +
`nvme-cli`). The official `telegraf` apt package was dropped from
Debian Trixie, so Docker is now the supported install path.

### 2a. Clone the repo onto the Pi

```bash
git clone <this-repo> ~/metrics_pi
cd ~/metrics_pi
```

### 2b. Identify SMART devices

```bash
sudo smartctl --scan
```

Record the device paths AND the `-d` type hint smartctl prints per Pi.
Typical output:

```
/dev/sda   -d sat   # /dev/sda [SAT], ATA device
/dev/nvme0 -d nvme  # /dev/nvme0, NVMe device
```

Note two things:
- NVMe disks appear as the controller char device `/dev/nvme0` — that's
  what smartctl uses. The block device `/dev/nvme0n1` is for filesystem
  I/O only; don't pass it to smartctl or Docker.
- USB-SATA bridges need the `-d sat` flag or smartctl returns
  "Unknown USB bridge". Copy the exact `-d ...` string into the
  `devices = [...]` list in `telegraf/telegraf.conf`.

### 2c. Create `.env`

```bash
cp .env.example .env
# edit .env: set HA_HOST, MQTT_USER, MQTT_PASS
```

`.env` is gitignored so the MQTT password stays local.

### 2d. Adjust device passthrough (if needed)

Open `docker-compose.yml` and edit the `devices:` list so it matches
the output of `smartctl --scan` on this Pi. The default is:

```yaml
devices:
  - /dev/nvme0n1:/dev/nvme0n1
  - /dev/sda:/dev/sda
```

Remove any lines whose host path doesn't exist — Docker refuses to
start the container if a listed device is missing.

### 2e. Build and start

```bash
docker compose up -d --build
docker compose logs -f telegraf
```

Expect log lines showing MQTT connect and periodic `Wrote batch of N
metrics`. Later updates: `git pull && docker compose up -d --build`.

### Bare-metal fallback (Bookworm only)

If you prefer not to run Docker, the original apt-based install still
works on Bookworm: `sudo apt-get install -y telegraf smartmontools
nvme-cli`, copy `telegraf/telegraf.conf` to `/etc/telegraf/` (replacing
the `${HA_HOST}` / `${MQTT_USER}` / `${MQTT_PASS}` placeholders with
literal values), deploy `telegraf/sudoers.d_telegraf` via `sudo visudo
-f /etc/sudoers.d/telegraf`, set `use_sudo = true` in the smart input,
then `sudo systemctl enable --now telegraf`. Not available on Trixie.

## Step 3 — Register HA entities (once per Pi)

Run the discovery script on each Pi. It auto-detects the hostname and
SMART devices via `smartctl --scan`, and reads `HA_HOST` / `MQTT_USER`
/ `MQTT_PASS` from the same `.env` you created in Step 2c:

```bash
sudo apt-get install -y mosquitto-clients
bash scripts/publish_discovery.sh
```

Alternatively, run once from a workstation by setting `FLEET` to a
space-separated list of `host:disk1,disk2,...` entries (still reads
`.env` for credentials):

```bash
FLEET="pi-a:nvme0,sda pi-b:nvme0,sda pi-c:nvme0" \
bash scripts/publish_discovery.sh
```

Re-run any time you add/remove a Pi or disk. Messages are retained so
HA recreates entities after restarts without re-running.

## Step 4 — Verify

1. Watch raw MQTT from a workstation:
   ```bash
   mosquitto_sub -h <HA_HOST> -u telegraf -P '<pass>' -t 'metrics_pi/#' -v
   ```
   Expect JSON every 30 s from each Pi, plus SMART every 5 min.

2. HA UI → **Settings → Devices & Services → MQTT → Devices**. Should
   list `pi-a`, `pi-b`, `pi-c` with 4–5 sensors each.

3. HA UI → **Developer Tools → States** → filter `pi_` — all sensors
   show numeric values, none say `unknown`.

4. InfluxDB addon UI → **Data Explorer** → bucket `homeassistant` →
   filter on your pi entity IDs. Points should accumulate.

## Step 5 — Grafana dashboard

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
| Container exits immediately with `error gathering PID` or `no such device` | A `/dev/...` entry in `docker-compose.yml` doesn't exist on this Pi — remove it |
| `smart` input logs `permission denied` inside the container | Container not `privileged: true`, or the device isn't passed through; re-check `docker-compose.yml` |
| No `smart` data at all | `smartctl --scan` returned nothing — USB adapter may need `-d sat,auto`; add `devices = ["/dev/sda -d sat"]` to `[[inputs.smart]]` |
| Hostname in MQTT topics is wrong | `network_mode: host` is required so Telegraf sees the Pi's real hostname; don't switch to bridge networking |
| HA shows entities but values are `unavailable` | State topic mismatch — check Telegraf is actually publishing to `metrics_pi/<host>/<plugin>`; run the `mosquitto_sub` command above |
| HA entities missing entirely | Discovery messages didn't land — re-run `publish_discovery.sh`; confirm MQTT integration in HA is configured with discovery prefix `homeassistant` (default) |
| InfluxDB has no data | `include.entity_globs` in `configuration.yaml` doesn't match actual entity IDs — check HA Developer Tools → States for real names, adjust globs |
| Grafana query returns empty | Wrong bucket/org/token on datasource, or `_measurement` filter wrong — in Flux, HA writes `_measurement` = unit string (e.g. `"%"`, `"°C"`) |

## Adding a fourth Pi

1. Run Step 2 on the new Pi (clone, `.env`, adjust `devices:` in
   `docker-compose.yml` for its disks, `docker compose up -d --build`).
2. Run Step 3 on the new Pi to publish its discovery configs.
3. Add globs in HA `configuration.yaml` if the hostname prefix changes.

No changes needed in HA UI or Grafana — new entities flow through
automatically, and any dashboard panel using `entity_id =~ /^pi_/`
picks them up.
