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
SENSOR_DIR=${SENSOR_DIR} SENSOR_VERSION=${V} docker compose -f compose.yaml up -d
curl -fsS http://127.0.0.1:9102/metrics | grep journal_delivery_pending_entries
```

`journal_delivery_pending_entries` is the number of journal lines waiting for the
backend to confirm them: it rises while the backend is unreachable and returns to
0 after. `SENSOR_IMAGE` points the service at a mirrored image. Change `mem_limit`,
`cpus`, `GOMAXPROCS` and `GOMEMLIMIT` to the host's budget.

On docker-compose 1.x use `docker-compose -f compose.yaml up -d`. Compose v2 warns
that `version` is obsolete; the warning is harmless.

## What each mount is for

| Mount | Why |
| --- | --- |
| `config`, `scrape-config` | The release's configuration and `overrides.yaml`, read-only |
| `state/positions` | Journal read positions and delivery checkpoints. Keep it across restarts and upgrades, or the whole retained journal is sent again |
| `state/vmagent_pq` | Metrics waiting while the backend is unreachable |
| `/` as `/host` | Host CPU, memory, disk and network metrics |
| `/var/log/journal` | The journal; a symlink into another disk works |
| `/etc/machine-id` | Finds this machine's journal directory |
| `/var/run/docker.sock` | Container names and metadata |

`NET_ADMIN` lets the sensor read per-process CPU and disk delay through the kernel's
taskstats interface; without it those two metrics are skipped.

## Offline buffering

Logs and metrics are buffered in different places:

| Data | Buffer | Its limit |
| --- | --- | --- |
| Journal logs | the journal itself: the sensor moves its position only past lines the backend accepted | journald's `SystemMaxUse` and `SystemMaxFiles`: lines journald deletes before they are sent are lost |
| Metrics | `state/vmagent_pq` | `maxDiskUsagePerURL`; when full, the oldest data is dropped |

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
`overrides.yaml`. To cap the buffer at the smaller of 20 GB and half the free space,
run this in the start-up script before `docker compose up`:

```bash
free_mb=$(( $(df -Pk "$SENSOR_DIR" | awk 'NR==2 {print $4}') / 1024 ))
cap_mb=$(( free_mb / 2 )); [ "$cap_mb" -gt 20480 ] && cap_mb=20480
sed -i '/^GC_EXPORTERS_REMOTEWRITE_MAXDISKUSAGEPERURL=/d' "$SENSOR_DIR/env.conf"
echo "GC_EXPORTERS_REMOTEWRITE_MAXDISKUSAGEPERURL=${cap_mb}MB" >> "$SENSOR_DIR/env.conf"
```

## Upgrades

Keep `$SENSOR_DIR/state` when you change `SENSOR_VERSION`: it holds the journal
checkpoints and the queued metrics. Replace `config/` and `scrape-config/` with
the new release's files, then reapply the placeholders and `overrides.yaml`.

## Known limits

- Do not enable `receivers.metricsscraper` with `read_only: true`: the scraper
  writes its configuration to the working directory and the sensor restarts in a loop.
- A crash dump arrives as one log row per pstore part. Filter on
  `journal_message` (the dump and part name) to group and order them.
