# Running the sensor with Docker Compose

`compose.yaml` runs the sensor as a read-only container without eBPF. All its files
live under `SENSOR_DIR` (default `/data/groundcover`). Compose only starts the
container; the files it mounts are prepared once per sensor version, then shipped
with the release.

Set `SENSOR_DIR` on hosts without `/data`, for example `/var/lib/groundcover`. It
holds the offline metrics buffer, so put it on a disk with room for
`maxDiskUsagePerURL`.

## Prepare

1. Pick the sensor version to pin, `V`. Reliable journald delivery and
   `contentField` need a release that includes them. Set the directory:
   `export SENSOR_DIR=/data/groundcover` (or another path), then `mkdir -p "$SENSOR_DIR"`.
2. Take the configuration from that release's package:
   ```bash
   curl -fsSL -o sensor.tgz \
     "https://github.com/groundcover-com/sensor-release/releases/download/release/sensor/${V}/groundcover-sensor-amd64.tar.gz"
   tar -xzf sensor.tgz -C "${SENSOR_DIR}" config scrape-config     # use -arm64 on arm64
   ```
3. Fill the two placeholders in `config/config.yaml` and `scrape-config/*.yaml`:
   `<GC_PLACEHOLDER_ENV_NAME>` (the environment name) and
   `<GC_PLACEHOLDER_DOMAIN>` (the ingestion host).
4. Copy `overrides.yaml` to `$SENSOR_DIR/config/overrides.yaml` and add your units
   under `serviceTargets`.
5. Copy `env.conf.example` to `$SENSOR_DIR/env.conf` (mode 600), set `API_KEY`,
   and `HTTPS_PROXY` if traffic goes through a proxy.
6. Create the state directories:
   `mkdir -p "$SENSOR_DIR"/state/positions "$SENSOR_DIR"/state/vmagent_pq`.

## Run

```bash
SENSOR_DIR=${SENSOR_DIR} SENSOR_VERSION=${V} docker compose -p groundcover -f compose.yaml up -d
curl -fsS http://127.0.0.1:9102/metrics | grep journal_delivery_pending_entries
```

`journal_delivery_pending_entries` is the number of journal lines waiting for the
backend to confirm them: it rises while the backend is unreachable and returns to
0 after. `SENSOR_IMAGE` points the service at a mirrored image. Change `mem_limit`,
`cpu_shares`, `GOMAXPROCS` and `GOMEMLIMIT` to the host's budget.

`cpu_shares` sets relative priority under CPU contention, not a hard CPU cap.
The example sets `GOMAXPROCS=1` to limit Go execution parallelism; it is not a
container CPU quota. A hard `cpus` limit requires kernel CFS bandwidth support
(`CONFIG_CFS_BANDWIDTH`), which some appliance kernels omit.

On docker-compose 1.x use `docker-compose -p groundcover -f compose.yaml up -d`.
Compose v2 warns that `version` is obsolete; the warning is harmless.

`-p groundcover` names the Compose project. Without it Compose names the project
after the directory holding `compose.yaml`, and fails when that is `/`. On a host
with a read-only root, keep these files on writable storage, e.g.
`$SENSOR_DIR/compose`.

## What each mount is for

| Mount | Why |
| --- | --- |
| `config`, `scrape-config` | The release's configuration and `overrides.yaml`, read-only |
| `state/positions` | Journal read positions and delivery checkpoints. Keep it across restarts and upgrades to preserve progress |
| `state/vmagent_pq` | Metrics waiting while the backend is unreachable |
| `/` as `/host` | Host CPU, memory, disk and network metrics |
| `/var/log/journal` | The journal; a symlink into another disk works |
| `/etc/machine-id` | Finds this machine's journal directory |
| `/var/run/docker.sock` | Container names and metadata |

`overrides.yaml` sets `logs.scraper.positionsFile` to
`/var/run/positions/positions.yaml`, inside the writable state mount. A relative
path such as `positions.yaml` resolves on the read-only container filesystem and
cannot be saved. Releases that persist an initial journal replay cutoff also keep
the adjacent `positions.yaml.journal-start` file here; preserve the entire directory.

`NET_ADMIN` lets the sensor read per-process CPU and disk delay through the kernel's
taskstats interface; without it those two metrics are skipped.

## Initial journal history

In sensor releases containing SEN-1339,
`logs.scraper.journalConfig.reliableDelivery.initialHistoryDuration` controls how
far back a fresh installation reads (default `24h`; for example, use `48h` or `1h`).
Omitting it or setting `0s` uses the default; negative durations are rejected.
The initial cutoff is persisted beside the positions file. Changing this setting
after startup does not move the saved cutoff or truncate recovery from an outage.
Existing reliable checkpoints continue to resume from their saved positions.
Older sensor releases do not apply this setting.

## Offline buffering

Logs and metrics are buffered in different places:

| Data | Buffer | Its limit |
| --- | --- | --- |
| Journal logs | the journal itself: the sensor moves its position only past lines the backend accepted | journald's `SystemMaxUse` and `SystemMaxFiles`: lines journald deletes before they are sent are lost |
| Metrics | `state/vmagent_pq` | `maxDiskUsagePerURL`; when full, the oldest data is dropped |

### Application containers must log to journald

Container logs are covered only when they reach the journal. Docker's default log
driver is `json-file`, so set `journald` as the daemon default
(`/etc/docker/daemon.json`: `{"log-driver": "journald"}`) or per service in your own
compose files (`logging: { driver: journald }`).

| Container log driver | What the sensor does |
| --- | --- |
| `journald` | reads it from the journal; kept through outages and reboots |
| `json-file`, on a host whose default is `json-file` | reads it through the Docker API; lost after a long outage |
| `json-file`, set on one container of a host whose default is `journald` | does not collect it |

### journald settings (host)

- `Storage=persistent`, with `/var/log/journal` on writable storage.
- `SystemMaxUse` and `SystemMaxFiles` large enough to hold the longest expected
  outage at your log rate.
- `RateLimitIntervalSec` / `RateLimitBurst` (default 10,000 lines per 30 s per unit):
  journald drops lines above it before any reader sees them. All containers log
  through `docker.service` and share one budget.

### Sizing the metrics buffer at start-up

Every setting can also come from an environment variable: `GC_` plus its path in
capitals, with `.` as `_`. The variable wins over `config.yaml` and
`overrides.yaml`. To cap the buffer at the smaller of 20 GB and half the space
available to it, run this in the start-up script before `docker compose up`:

```bash
queue_mb=$(( $(du -sk "$SENSOR_DIR/state/vmagent_pq" | cut -f1) / 1024 ))
free_mb=$(( $(df -Pk "$SENSOR_DIR" | awk 'NR==2 {print $4}') / 1024 ))
cap_mb=$(( (free_mb + queue_mb) / 2 ))
[ "$cap_mb" -gt 20480 ] && cap_mb=20480
[ "$cap_mb" -lt 256 ] && cap_mb=256
sed -i '/^GC_EXPORTERS_REMOTEWRITE_MAXDISKUSAGEPERURL=/d' "$SENSOR_DIR/env.conf"
echo "GC_EXPORTERS_REMOTEWRITE_MAXDISKUSAGEPERURL=${cap_mb}MB" >> "$SENSOR_DIR/env.conf"
```

The queue's own size counts as available, so a reboot during an outage does not
shrink the cap below the data already queued and drop it. The floor keeps the cap
from reaching 0, which means unlimited.

## Upgrades

Keep `$SENSOR_DIR/state` when you change `SENSOR_VERSION`: it holds the journal
checkpoints and the queued metrics. Replace `config/` and `scrape-config/` with
the new release's files, then reapply the placeholders and `overrides.yaml`.

## Known limits

- Do not enable `receivers.metricsscraper` with `read_only: true`: the scraper
  writes its configuration to the working directory and the sensor restarts in a loop.
- A crash dump arrives as one log row per pstore part. Filter on
  `journal_message` (the dump and part name) to group and order them.
