"""Sandboxed tests: no host services, logs, or /etc files are changed."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'logkeeper.sh'
BASH = os.environ.get('LOGKEEPER_BASH', 'bash')


class SettingsTests(unittest.TestCase):
    def run_shell(self, code):
        return subprocess.run([BASH, '-c', 'source "$1"; ' + code, '_', str(SOURCE)], capture_output=True, text=True)

    def test_defaults(self):
        self.assertEqual(self.run_shell('validate; calendar; render_xui').returncode, 0)

    def test_reject_invalid(self):
        for assignment in ['MAX_MB=0', 'MAX_MB=10001', 'KEEP=0', 'KEEP=31', 'INTERVAL=17', 'JOURNAL_MB=1', 'MAX_MB="1;id"']:
            with self.subTest(assignment=assignment):
                self.assertNotEqual(self.run_shell(assignment + '; validate').returncode, 0)

    def test_calendars(self):
        for interval in [15, 30, 60, 180, 360, 720, 1440]:
            r = self.run_shell(f'INTERVAL={interval}; validate; calendar')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue(r.stdout.strip())

    def test_allowlist(self):
        text = self.run_shell('render_xui').stdout
        self.assertIn('3xipl-ap.prev.log', text)
        self.assertNotIn('*.log', text)
        self.assertIn('copytruncate', text)


@unittest.skipIf(os.name == 'nt', 'Linux filesystem integration cases run in GitHub Actions')
class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.script = self.root / 'logkeeper.sh'
        code = SOURCE.read_text()
        # Redirect every managed absolute path into the fixture root.
        for prefix in ['/etc/', '/var/', '/run/', '/usr/local/sbin/']:
            code = code.replace(prefix, str(self.root) + prefix)
        self.script.write_text(code)
        self.mocks = self.root / 'mocks'
        self.mocks.mkdir()
        self.env = dict(os.environ, PATH=str(self.mocks) + ':' + os.environ['PATH'])
        self.mock('systemctl', '''case "$1" in
is-enabled) echo enabled;;
is-active) echo inactive; exit 3;;
show) echo inactive;;
esac
''')
        self.mock('logrotate', 'exit "${TEST_ROTATE_EXIT:-0}"\n')
        self.mock('journalctl', 'exit 0\n')
        self.mock('apt-get', 'exit 0\n')
        self.original = '/var/log/syslog\n{\n weekly\n rotate 4\n compress\n delaycompress\n postrotate\n /usr/lib/rsyslog/rsyslog-rotate\n endscript\n}\n'
        self.file('/etc/logrotate.d/rsyslog').write_text(self.original)

    def tearDown(self):
        self.tmp.cleanup()

    def file(self, path):
        p = self.root / path.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def mock(self, name, content):
        p = self.mocks / name
        p.write_text('#!/bin/sh\n' + content)
        p.chmod(0o755)

    def run_action(self, action, inputs='', extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        # Only preflight/root/outer lock are mocked; file edits and generated code run unchanged.
        code = 'source "$1"; root(){ :; }; platform(){ :; }; lock(){ :; }; ' + action
        return subprocess.run([BASH, '-c', code, '_', str(self.script)], input=inputs, capture_output=True, text=True, env=env)

    def install(self):
        result = self.run_action('configure', '\n\n\n\nYES\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_install_reconfigure_uninstall(self):
        self.install()
        policy = self.file('/etc/logrotate.d/rsyslog').read_text()
        self.assertIn('maxsize 100M', policy)
        self.assertIn('postrotate', policy)
        result = self.run_action('configure', '50\n2\n15\n100\nYES\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('size 50M', self.file('/etc/logrotate-x-ui.conf').read_text())
        self.assertIn('0/15', self.file('/etc/systemd/system/x-ui-logrotate.timer').read_text())
        result = self.run_action('uninstall_tool', 'YES\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.file('/etc/logrotate.d/rsyslog').read_text(), self.original)
        self.assertFalse(self.file('/etc/logrotate-x-ui.conf').exists())

    def test_decline_and_invalid_do_not_write(self):
        self.run_action('configure', '\n\n\n\nNO\n')
        self.assertFalse(self.file('/etc/server-logkeeper.conf').exists())
        self.assertNotEqual(self.run_action('configure', '0\n3\n60\n200\n').returncode, 0)
        self.assertEqual(self.file('/etc/logrotate.d/rsyslog').read_text(), self.original)

    def test_validation_failure_rolls_back_update(self):
        self.install()
        before = self.file('/etc/logrotate.d/rsyslog').read_text()
        result = self.run_action('configure', '50\n2\n15\n100\nYES\n', {'TEST_ROTATE_EXIT': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.file('/etc/logrotate.d/rsyslog').read_text(), before)
        self.assertIn('MAX_MB=100', self.file('/etc/server-logkeeper.conf').read_text())

    def test_first_install_failure_restores_original(self):
        result = self.run_action('configure', '\n\n\n\nYES\n', {'TEST_ROTATE_EXIT': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.file('/etc/logrotate.d/rsyslog').read_text(), self.original)
        self.assertFalse(self.file('/etc/logrotate-x-ui.conf').exists())
        self.assertNotIn('unbound variable', result.stderr)

    def test_real_logrotate_accepts_generated_policy(self):
        executable = shutil.which('logrotate')
        if not executable:
            self.skipTest('logrotate is not installed')
        self.install()
        result = subprocess.run([executable, '--debug', '--state', str(self.root / 'test-state'), str(self.file('/etc/logrotate-x-ui.conf'))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_config_is_not_executed(self):
        marker = self.root / 'pwned'
        self.file('/etc/server-logkeeper.conf').write_text(f'MAX_MB=$(touch {marker})\n')
        self.assertNotEqual(self.run_action('load').returncode, 0)
        self.assertFalse(marker.exists())

    def test_emergency_cleanup_allowlist_and_tail(self):
        self.file('/var/log/x-ui/3xui.log').write_bytes(b'x' * 1500000)
        self.file('/var/log/x-ui/unrelated.db').write_bytes(b'keep')
        result = self.run_action('clean', 'YES\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.file('/var/log/x-ui/3xui.log').stat().st_size, 0)
        self.assertEqual(self.file('/var/log/x-ui/unrelated.db').read_bytes(), b'keep')
        import gzip
        self.assertEqual(len(gzip.decompress(self.file('/var/log/x-ui/3xui.log.cleanup-tail.gz').read_bytes())), 1048576)

    def test_emergency_cleanup_rejects_symlink(self):
        target = self.file('/var/valuable')
        target.write_text('keep')
        self.file('/var/log/x-ui/3xui.log').symlink_to(target)
        self.assertNotEqual(self.run_action('clean', 'YES\n').returncode, 0)
        self.assertEqual(target.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main(verbosity=2)
