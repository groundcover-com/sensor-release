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
