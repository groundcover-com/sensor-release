# Running the sensor with Docker Compose

`compose.yaml` runs the sensor as a read-only container without eBPF, with all
its files under `SENSOR_DIR` (default `/data/groundcover`). Compose only starts
the container; the files it mounts are prepared once per sensor version, then
shipped with the release.

Set `SENSOR_DIR` on hosts without `/data`, for example `/var/lib/groundcover`.
It holds the offline metrics buffer, so put it on a disk with room for
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
4. Copy `overrides.yaml` to `$SENSOR_DIR/config/overrides.yaml`. Change
   `maxDiskUsagePerURL` there to size the offline metrics buffer.
5. Copy `env.conf.example` to `$SENSOR_DIR/env.conf` (mode 600) and set
   `API_KEY`.
6. Create the state directories:
   `mkdir -p "$SENSOR_DIR"/state/positions "$SENSOR_DIR"/state/vmagent_pq`.

## Run

```bash
SENSOR_DIR=${SENSOR_DIR} SENSOR_VERSION=${V} docker compose -f compose.yaml up -d
curl -fsS http://127.0.0.1:2021/health          # healthy
curl -fsS http://127.0.0.1:9102/metrics | head  # sensor metrics
```

`SENSOR_IMAGE` points the service at a mirrored image. Change `mem_limit`,
`cpus`, `GOMAXPROCS` and `GOMEMLIMIT` to the host's budget.

## What each mount is for

| Mount | Why |
| --- | --- |
| `config`, `scrape-config` | Sensor configuration, read-only |
| `state/positions` | Read positions and journal delivery checkpoints |
| `state/vmagent_pq` | Metrics queued while offline |
| `/` as `/host` | Host metrics (CPU, memory, disk, network) |
| `/var/log/journal` | The persistent journal |
| `/etc/machine-id` | Finds this machine's journal directory |
| `/var/run/docker.sock` | Container names and metadata |
