# Docker installer acceptance contract

These tests specify the `SENSOR_INSTALL_MODE=docker` path of `install.sh`. The
existing systemd install remains the default.

The customer runs the installer from the device, passing an ingestion key,
environment, BYOC hostname and optional `SENSOR_VERSION`. On the host, Docker
mode needs only Docker, root, `curl` and a writable `SENSOR_DOCKER_DATA_DIR`: no
uploaded bundle, Docker Compose, or writable `/etc` or `/opt`. It downloads the
release configuration and runs the matching published image with eBPF disabled,
a read-only container root and persistent state under `SENSOR_DOCKER_DATA_DIR`
(default `/data/groundcover`). Docker's restart policy starts it again after
daemon restarts and host reboots. Docker mode also turns on reliable journald
delivery (`reliableDelivery.enabled` under `journalConfig`), so journal logs
written while the host is offline are sent after it reconnects; sensor releases
without that feature ignore the setting. Reinstall updates the container while
preserving that state. Uninstall removes the managed container and preserves
the data directory.

The published image has no `latest` tag, so an unpinned Docker install resolves
`latest` to the newest release and runs that tag. Native/systemd installation
keeps its existing version behavior. Buffering and replay are outside this
change.

Run on a Linux Docker host that allows privileged containers (the appliance runs
its own Docker daemon) and reaches Docker Hub, the Alpine package mirror, GitHub
and public ECR:

```bash
python3 -m unittest discover -s tests -v
```

The driver builds a Docker 25.0.3 appliance image with Bash/curl and a local
HTTPS destination. It gives the appliance a read-only root, temporary run/log
directories and a persistent `/data` volume, then runs the actual installer
from `/`. The nested daemon keeps its data in `/data/var/lib/docker` and uses
the host's cgroup version. It pulls the actual release package and published
sensor image. A synthetic key and a local HTTPS destination keep this test
independent of any real tenant.

The successful-install scenario observes the running container, health
endpoint, mounts, environment, generated configuration and retained state
across reinstall and uninstall. The no-BTF scenario hides `/sys/kernel/btf` from
the appliance, as on kernels built without `CONFIG_DEBUG_INFO_BTF`, and requires
the sensor to keep pushing host metrics. All owned containers, data volumes,
networks and fixture images are removed. No host Docker data or existing
containers are changed.

For another published release, set `TEST_SENSOR_VERSION`. The default is the
known published release `1.13.90`. These are installer acceptance tests; they
do not certify a particular appliance kernel or a customer's BYOC tenant.
