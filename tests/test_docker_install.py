"""Run with: python3 -m unittest discover -s tests -v.

Requires Docker with privileged containers (the appliance runs its own Docker
daemon) and outbound access to Docker Hub, the Alpine mirror, GitHub and public ECR.
The driver runs the public installer against a read-only appliance fixture,
an actual Docker 25.0.3 daemon and the published sensor image. It never uses
systemd or a real groundcover tenant. All owned resources are removed.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time
import unittest
import uuid


def command(args, *, timeout=180, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f'{args[0]} exited {result.returncode}:\n{result.stdout}\n{result.stderr}')
    return result


class Appliance:
    """Drive installer commands and observe the appliance's Docker/filesystem API."""

    def __init__(self, image, *, kernel_btf=True):
        self.id = 'sensor-install-' + uuid.uuid4().hex[:12]
        self.image = image
        # Appliance kernels built without CONFIG_DEBUG_INFO_BTF expose no /sys/kernel/btf.
        self.kernel_btf = kernel_btf
        self.backend = self.id + '-backend'
        self.volume = self.id + '-data'
        self.temp = tempfile.TemporaryDirectory(prefix=self.id)
        self.files = Path(self.temp.name)
        self.version = os.environ.get('TEST_SENSOR_VERSION', '1.13.90')
        self.api_key = 'test-key-' + uuid.uuid4().hex
        self.environment = 'test-' + uuid.uuid4().hex[:12]

    def __enter__(self):
        try:
            self._start()
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def _start(self):
        (self.files / 'machine-id').write_text(uuid.uuid4().hex + '\n')
        command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                 '-keyout', str(self.files / 'key.pem'), '-out', str(self.files / 'cert.pem'),
                 '-days', '1', '-subj', '/CN=groundcover-test', '-addext',
                 'subjectAltName=DNS:groundcover-test,DNS:metrics-http.groundcover-test'])
        command(['docker', 'network', 'create', self.id])
        command(['docker', 'volume', 'create', self.volume])
        command(['docker', 'run', '-d', '--name', self.backend, '--network', self.id,
                 '--network-alias', 'groundcover-test', '--network-alias', 'metrics-http.groundcover-test',
                 '--read-only', '-v', f'{self.files}:/fixtures:ro', '--entrypoint', 'python3',
                 self.image, '/test-backend.py'])
        installer = Path(__file__).resolve().parents[1] / 'install.sh'
        hide_btf = [] if self.kernel_btf else ['--mount', 'type=tmpfs,destination=/sys/kernel/btf,readonly']
        command(['docker', 'run', '-d', '--name', self.id, '--network', self.id, *hide_btf,
                 '--privileged', '--memory', '3g', '--read-only', '--tmpfs', '/run:rw,size=64m',
                 '--tmpfs', '/tmp:rw,size=64m', '--tmpfs', '/var/log:rw,size=16m',
                 '-v', f'{self.volume}:/data', '-v', f'{self.files}:/fixtures:ro',
                 '-v', f'{self.files / "machine-id"}:/etc/machine-id:ro',
                 '-v', f'{installer}:/install.sh:ro', '--entrypoint', '/usr/local/bin/dind',
                 self.image, 'dockerd', '--host=unix:///run/docker.sock',
                 '--data-root=/data/var/lib/docker', '--exec-root=/run/docker',
                 '--pidfile=/run/docker.pid', '--storage-driver=overlay2',
                 '--iptables=false', '--bridge=none', '--ip-forward=false'])
        self.wait(lambda: self.host(['docker', 'info'], check=False).returncode == 0)
        machine_id = (self.files / 'machine-id').read_text().strip()
        self.host(['mkdir', '-p', '/var/log/journal/' + machine_id])

    def host(self, args, *, check=True, timeout=180):
        return command(['docker', 'exec', self.id] + args, check=check, timeout=timeout)

    def install(self, **overrides):
        values = {'SENSOR_INSTALL_MODE': 'docker', 'SENSOR_VERSION': self.version,
                  'API_KEY': self.api_key, 'GC_ENV_NAME': self.environment,
                  'GC_DOMAIN': 'groundcover-test', 'CURL_CA_BUNDLE': '/fixtures/cert.pem'}
        values.update(overrides)
        args = ['docker', 'exec']
        for key, value in values.items():
            args += ['-e', f'{key}={value}']
        # The caller starts in '/', which is read-only, as a piped installer can.
        return command(args + [self.id, 'bash', '/install.sh', 'install'], check=False, timeout=300)

    def sensor(self):
        result = self.host(['docker', 'inspect', 'groundcover-sensor'])
        return json.loads(result.stdout)[0]

    def wait(self, predicate, timeout=120, failure='Appliance did not become ready'):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(1)
        logs = self.host(['docker', 'logs', '--tail', '30', 'groundcover-sensor'], check=False)
        raise AssertionError(failure + ':\n' + logs.stdout + logs.stderr)

    def wait_for_sensor(self):
        self.wait(lambda: self.host(['curl', '-fsS', '--max-time', '2',
                                     'http://127.0.0.1:2021/health'], check=False).returncode == 0)

    def read(self, path):
        return self.host(['cat', path]).stdout

    def sensor_metric(self, name):
        exposition = self.host(['curl', '-fsS', '--max-time', '2', 'http://127.0.0.1:9102/metrics'],
                               check=False).stdout
        return sum(float(line.split()[-1]) for line in exposition.splitlines()
                   if line.split(' ')[0].split('{')[0] == name)

    def __exit__(self, *_):
        for name in [self.id, self.backend]:
            command(['docker', 'rm', '-f', name], check=False)
        command(['docker', 'volume', 'rm', '-f', self.volume], check=False)
        command(['docker', 'network', 'rm', self.id], check=False)
        self.temp.cleanup()


class DockerInstallTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = 'sensor-installer-test:' + uuid.uuid4().hex[:12]
        command(['docker', 'build', '-q', '-t', cls.image,
                 str(Path(__file__).parent / 'fixtures')], timeout=300)

    @classmethod
    def tearDownClass(cls):
        command(['docker', 'image', 'rm', cls.image], check=False)

    def test_pinned_install_runs_on_a_read_only_host_and_updates_without_losing_state(self):
        with Appliance(self.image) as appliance:
            result = appliance.install()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            appliance.wait_for_sensor()
            sensor = appliance.sensor()
            self.assertEqual(sensor['Config']['Image'],
                             'public.ecr.aws/groundcovercom/sensor:' + appliance.version)
            self.assertTrue(sensor['HostConfig']['ReadonlyRootfs'])
            self.assertEqual(sensor['HostConfig']['RestartPolicy']['Name'], 'unless-stopped')
            self.assertIn('FLORA_EBPFENABLED=false', sensor['Config']['Env'])
            self.assertIn('API_KEY=' + appliance.api_key, sensor['Config']['Env'])
            mounts = {m['Destination']: m for m in sensor['Mounts']}
            self.assertEqual(mounts['/var/run/positions']['Source'],
                             '/data/groundcover/state/positions')
            self.assertTrue(mounts['/var/run/positions']['RW'])
            self.assertTrue(mounts['/vmagent_pq']['RW'])
            self.assertFalse(mounts['/config']['RW'])
            config = appliance.read('/data/groundcover/config/config.yaml')
            self.assertIn(appliance.environment, config)
            self.assertIn('/var/run/positions/positions.yaml', config)
            self.assertNotIn('<GC_PLACEHOLDER_', config)

            # Reinstall is the customer's update path; existing state must survive.
            sentinel = 'state-' + uuid.uuid4().hex
            appliance.host(['sh', '-c', 'printf "%s" "$1" > "$2"', 'sh', sentinel,
                            '/data/groundcover/state/positions/keep'])
            result = appliance.install()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            appliance.wait_for_sensor()
            self.assertEqual(appliance.read('/data/groundcover/state/positions/keep'), sentinel)

            # Removing a container must not remove the persistent data directory.
            appliance.host(['env', 'SENSOR_INSTALL_MODE=docker', 'bash', '/install.sh', 'uninstall'])
            self.assertNotEqual(appliance.host(['docker', 'inspect', 'groundcover-sensor'],
                                               check=False).returncode, 0)
            self.assertEqual(appliance.read('/data/groundcover/state/positions/keep'), sentinel)

    def test_install_without_kernel_btf_still_reports_host_metrics(self):
        # Without BTF the eBPF loader fails, and that failure stops every flora module,
        # host metrics included, while the sensor itself stays healthy.
        with Appliance(self.image, kernel_btf=False) as appliance:
            self.assertNotEqual(appliance.host(['test', '-e', '/sys/kernel/btf/vmlinux'],
                                               check=False).returncode, 0)
            result = appliance.install()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            appliance.wait_for_sensor()
            appliance.wait(lambda: appliance.sensor_metric('exporters_remotewrite_rows_pushed_sum') > 0,
                           failure='Sensor never pushed host metrics')
            self.assertEqual(appliance.sensor_metric('flora_listener_error_total'), 0)


if __name__ == '__main__':
    unittest.main()
