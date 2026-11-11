"""Run in a disposable Linux container: the installer writes a systemd unit."""
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import uuid


@unittest.skipUnless(Path('/.dockerenv').exists() and os.geteuid() == 0,
                     'requires a disposable Linux container running as root')
class InstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.service = 'sensor-install-test-' + uuid.uuid4().hex + '.service'
        self.unit = Path('/etc/systemd/system') / self.service
        self.unit.parent.mkdir(parents=True, exist_ok=True)
        self.addCleanup(lambda: self.unit.unlink(missing_ok=True))
        package = self.root / 'package'
        (package / 'config').mkdir(parents=True)
        (package / 'scrape-config').mkdir()
        (package / 'groundcover-sensor').write_text('#!/bin/sh\nexit 0\n')
        (package / 'groundcover-sensor').chmod(0o755)
        (package / 'config/config.yaml').write_text(
            'envType: host\nenv: <GC_PLACEHOLDER_ENV_NAME>\n')
        for name in ['logs', 'metrics']:
            (package / f'scrape-config/{name}-scrape-config.yaml').write_text(
                'endpoint: <GC_PLACEHOLDER_DOMAIN>\n')
        archive = self.root / 'release.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for child in package.iterdir():
                tar.add(child, arcname=child.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        commands = {
            'uname': '#!/bin/sh\necho x86_64\n',
            'curl': '''#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; out=$1; fi
    shift
done
if [ "$out" != /dev/null ]; then cp "$TEST_ARCHIVE" "$out" || exit 1; fi
printf 200
''',
            'systemctl': '''#!/bin/sh
case "$1" in
    is-active) test -f "$TEST_SERVICE_STATE" ;;
    start) touch "$TEST_SERVICE_STATE" ;;
    stop) rm -f "$TEST_SERVICE_STATE" ;;
    *) exit 0 ;;
esac
''',
        }
        for name, script in commands.items():
            (bin_dir / name).write_text(script)
            (bin_dir / name).chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
                        API_KEY='synthetic-key', GC_ENV_NAME='test-env',
                        GC_DOMAIN='ingest.example.com', SENSOR_VERSION='1.13.204',
                        SENSOR_INSTALL_DIR=str(self.root / 'install'),
                        SENSOR_ENV_DIR=str(self.root / 'env'),
                        SENSOR_SERVICE_NAME=self.service,
                        TEST_ARCHIVE=str(archive),
                        TEST_SERVICE_STATE=str(self.root / 'running'), TERM='dumb')
        self.installer = Path(__file__).resolve().parents[1] / 'install.sh'

    def install(self, *args, succeeds=True):
        result = subprocess.run(['bash', str(self.installer), *args],
                                cwd=self.root, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_normal_and_edge_updates_set_service_environment_and_preserve_overrides(self):
        self.install('install')
        env_path = self.root / 'env/env.conf'
        self.assertNotIn('GC_ENVTYPE=', env_path.read_text())
        self.assertIn(f'EnvironmentFile={env_path}', self.unit.read_text())
        override = self.root / 'env/overrides.yaml'
        original = 'envType: host\nlogs:\n  scraper:\n    positionsFile: /data/positions.yaml\n'
        override.write_text(original)
        self.install('install', '--edge')
        self.assertIn('GC_ENVTYPE=edge\n', env_path.read_text())
        self.assertEqual(override.read_text(), original)
        self.install('install', '--edge')
        self.assertEqual(env_path.read_text().count('GC_ENVTYPE=edge\n'), 1)
        self.install('install')
        self.assertNotIn('GC_ENVTYPE=', env_path.read_text())
        self.assertEqual(override.read_text(), original)

    def test_invalid_options_do_not_install_or_uninstall(self):
        for args in [('install', '--edeg'), ('install', '--edge', 'extra'),
                     ('uninstall', '--edge'), ('--edge',)]:
            with self.subTest(args=args):
                result = self.install(*args, succeeds=False)
                self.assertIn('Usage:', result.stdout)
                self.assertFalse(self.unit.exists())
                self.assertFalse((self.root / 'install').exists())


if __name__ == '__main__':
    unittest.main()
