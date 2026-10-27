"""Checks of install.sh functions that run without a host install."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

INSTALL_SH = Path(__file__).resolve().parent.parent / 'install.sh'


def ebpf_setting(btf_present, choice=None):
    """Runs ebpfSetting from install.sh with or without a BTF file."""
    with tempfile.TemporaryDirectory() as directory:
        btf = Path(directory) / 'vmlinux'
        if btf_present:
            btf.touch()
        env = {k: v for k, v in os.environ.items() if k != 'FLORA_EBPFENABLED'}
        env['SENSOR_BTF_PATH'] = str(btf)
        if choice is not None:
            env['FLORA_EBPFENABLED'] = choice
        script = ('log_error() { echo "$*" >&2; }; '
                  'eval "$(sed -n \'/^ebpfSetting() {/,/^}/p\' "$1")"; ebpfSetting')
        return subprocess.run(['bash', '-c', script, '_', str(INSTALL_SH)],
                              env=env, capture_output=True, text=True)


class EbpfSettingTest(unittest.TestCase):
    def test_unset_keeps_flora_default_where_the_kernel_has_btf(self):
        result = ebpf_setting(btf_present=True)
        self.assertEqual((result.returncode, result.stdout), (0, ''))

    def test_unset_turns_ebpf_off_without_btf_so_host_metrics_keep_flowing(self):
        result = ebpf_setting(btf_present=False)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, 'false'))

    def test_true_without_btf_is_refused(self):
        result = ebpf_setting(btf_present=False, choice='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('needs a kernel with BTF', result.stderr)

    def test_true_with_btf_and_false_anywhere_pass_through(self):
        self.assertEqual(ebpf_setting(btf_present=True, choice='true').stdout.strip(), 'true')
        self.assertEqual(ebpf_setting(btf_present=False, choice='false').stdout.strip(), 'false')

    def test_other_values_are_refused(self):
        self.assertNotEqual(ebpf_setting(btf_present=True, choice='yes').returncode, 0)


if __name__ == '__main__':
    unittest.main()
