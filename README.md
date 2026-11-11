# groundcover Sensor Releases

Welcome to the **groundcover Sensor Releases** repository! 🐝 

## 📦 Repository Contents

### Releases
Each release includes:
- **binaries** (TBD)

Head to the [Releases](https://github.com/groundcover-com/sensor-release/releases) page to download the latest version.

## Install a specific version

Set `SENSOR_VERSION` to a release version such as `1.12.383`. The installer selects
the package for your machine's architecture (`amd64` or `arm64`).

Use the Linux hosts installation command from the app or
[documentation](https://docs.groundcover.com/getting-started/installation-and-updating/connect-linux-hosts),
adding `SENSOR_VERSION` after `sudo env`:

```bash
curl -fsSL https://groundcover.com/install-groundcover-sensor.sh |
  sudo env \
    API_KEY='{ingestion_Key}' GC_ENV_NAME='{selected_Env}' GC_DOMAIN='{BYOC_ENDPOINT}' \
    SENSOR_VERSION=1.12.383 \
    bash -s -- install
```

Omit `SENSOR_VERSION` or set it to `latest` to keep installing the latest release.
A specific version downloads directly from its GitHub release. If that download
fails, installation stops; it does not fall back to the latest release.

`SENSOR_RELEASE_URL_PREFIX` remains available for custom download locations. It
cannot be combined with a specific `SENSOR_VERSION`.

Version pinning selects a release; it does not verify artifact integrity. The
command above still downloads the installer from `main`.

## Install an edge sensor

Add `--edge` after `install` to report the sensor's environment type as `edge`:

```bash
curl -fsSL https://groundcover.com/install-groundcover-sensor.sh |
  sudo env \
    API_KEY='{ingestion_Key}' GC_ENV_NAME='{selected_Env}' GC_DOMAIN='{BYOC_ENDPOINT}' \
    bash -s -- install --edge
```

You can combine this with `SENSOR_VERSION` to pin a release. The flag writes
`GC_ENVTYPE=edge` into the service's `env.conf`, overriding `envType` in the base
configuration and `overrides.yaml` without changing either file. The sensor uses
this value for `env_type` on its telemetry, including measurements.

Pass `--edge` again on each install or update. Without it, the installer leaves
the environment type to the sensor configuration (`host` in the standalone
release). The flag does not disable eBPF or change collection settings.

For Docker Compose, which does not run this installer, add `GC_ENVTYPE=edge` to
the sensor's `env.conf` and recreate the container.
