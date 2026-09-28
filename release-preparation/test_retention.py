#!/usr/bin/env python3
"""Regression tests. Only temporary fixtures and stubbed virsh calls are used."""
import datetime as dt
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BACKUP = Path(os.environ.get('VM_BACKUP_SOURCE', REPO / 'VMBackup/vm_backup.sh'))
RESTORE = REPO / 'VMBackup/vm_restore.sh'
SOURCE = BACKUP.read_text()


def function(text, name):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', text, re.M | re.S)
    if not match:
        raise RuntimeError('Function not found: ' + name)
    return match.group(0)


FUNCTIONS = '\n'.join(function(SOURCE, name) for name in ['backup_dir_sort_key', 'cleanup_old_backups'])


class RetentionTests(unittest.TestCase):
    def check_case(self, names, keep, expected, root_name='backups', extras=(), failed=False):
        with tempfile.TemporaryDirectory(prefix='vm-retention-test-') as temporary:
            root = Path(temporary) / root_name
            root.mkdir()
            for name in [*names, *extras]:
                (root / name / 'vm').mkdir(parents=True)
                (root / name / 'vm' / 'test.xml').write_text('<domain/>')
                (root / name / 'vm' / 'disk.qcow2').write_text('DUMMY TEST DATA')
            outside = Path(temporary) / 'outside'
            outside.mkdir()
            (outside / 'keep').write_text('KEEP')
            (root / '2000_01_01_00-00-00').symlink_to(outside, target_is_directory=True)
            (root / '1999_01_01_00-00-00').write_text('NOT A DIRECTORY')
            code = 'log() { :; }\n' + FUNCTIONS + '\ncleanup_old_backups\n'
            env = dict(os.environ, BACKUP_ROOT=str(root), RETENTION_COUNT=str(keep), BACKUP_OK='0' if failed else '1')
            result = subprocess.run(['bash', '-c', code], env=env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = {name for name in names if (root / name).is_dir()}
            self.assertEqual(actual, set(expected), result.stdout + result.stderr)
            for name in extras:
                self.assertTrue((root / name / 'vm' / 'disk.qcow2').exists(), name)
            self.assertTrue((outside / 'keep').exists())
            self.assertTrue((root / '2000_01_01_00-00-00').is_symlink())
            self.assertTrue((root / '1999_01_01_00-00-00').is_file())

    def test_disabled(self):
        names = ['31_08_2026_12-00-00', '2026_09_02_12-00-00']
        self.check_case(names, 0, names)

    def test_empty(self):
        self.check_case([], 1, [])

    def test_failed_backup_preserves_existing(self):
        names = ['2026_09_01_00-00-00', '2026_09_02_00-00-00']
        self.check_case(names, 1, names, failed=True)

    def test_invalid_date_directory_is_preserved(self):
        self.check_case(['2026_09_01_00-00-00', '2026_09_02_00-00-00'], 1, ['2026_09_02_00-00-00'],
                        extras=['2026_99_99_99-99-99', '2026_02_30_00-00-00', '00_12_2026_00-00-00'])

    def test_invalid_retention_is_disabled(self):
        names = ['2026_09_01_00-00-00', '2026_09_02_00-00-00']
        for keep in ['-1', '1.0', 'invalid', '99999999999999999999']:
            with self.subTest(keep=keep):
                self.check_case(names, keep, names)

    def test_leading_zero_retention(self):
        names = [f'2026_09_{day:02}_00-00-00' for day in range(1, 10)]
        self.check_case(names, '08', names[1:])

    def test_more_slots_than_backups(self):
        names = ['31_08_2026_12-00-00', '2026_09_02_12-00-00']
        self.check_case(names, 4, names)

    def test_exact_retention(self):
        names = ['31_08_2026_12-00-00', '2026_09_02_12-00-00']
        self.check_case(names, 2, names)

    def test_unrelated_directories(self):
        self.check_case(['2026_09_01_00-00-00', '2026_09_02_00-00-00'], 1, ['2026_09_02_00-00-00'],
                        extras=['Archive', 'Screens', 'my backup', '2026_09_01_00-00-00-copy', 'dir\n2026_09_03_00-00-00'])

    def test_deterministic_mixed_calendar(self):
        dates = [dt.datetime(2024, 12, 20) + dt.timedelta(days=i * 9, seconds=i) for i in range(100)]
        names = [date.strftime('%Y_%m_%d_%H-%M-%S' if i % 2 else '%d_%m_%Y_%H-%M-%S') for i, date in enumerate(dates)]
        self.check_case(names[::-1], 4, names[-4:])

    def test_calendar_validation(self):
        valid = ['2024_02_29_23-59-59', '29_02_2000_00-00-00', '2026_08_09_08-09-09']
        invalid = ['2023_02_29_00-00-00', '29_02_1900_00-00-00', '2026_04_31_00-00-00',
                   '2026_00_01_00-00-00', '2026_13_01_00-00-00', '2026_01_00_00-00-00',
                   '0000_01_01_00-00-00', '2026_01_01_24-00-00', '2026_01_01_00-60-00',
                   '2026_01_01_00-00-60', '2026_01_01_00-00-00.tmp', 'notes']
        code = function(SOURCE, 'backup_dir_sort_key') + '\nbackup_dir_sort_key "$1"'
        for name in [*valid, *invalid]:
            with self.subTest(name=name):
                result = subprocess.run(['bash', '-c', code, 'test', name], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0 if name in valid else 1)


CASES = {
    'legacy_month': (['29_08_2026_23-00-00', '01_09_2026_23-00-00'], ['01_09_2026_23-00-00']),
    'legacy_year': (['31_12_2025_23-59-59', '01_01_2026_00-00-00'], ['01_01_2026_00-00-00']),
    'new_month': (['2026_08_29_23-00-00', '2026_09_01_23-00-00'], ['2026_09_01_23-00-00']),
    'new_year': (['2025_12_31_23-59-59', '2026_01_01_00-00-00'], ['2026_01_01_00-00-00']),
    'time_of_day': (['2026_09_28_08-00-00', '2026_09_28_09-00-00', '2026_09_28_09-00-01'], ['2026_09_28_09-00-01']),
    'mixed_migration': (['31_08_2026_12-00-00', '01_09_2026_12-00-00', '2026_09_02_12-00-00'], ['01_09_2026_12-00-00', '2026_09_02_12-00-00']),
}
for label, (names, expected) in CASES.items():
    def case(self, names=names, expected=expected):
        self.check_case(names, len(expected), expected)
    setattr(RetentionTests, 'test_' + label, case)
for label, root_name in {'spaces': 'VM Backups', 'tabs': 'VM\tBackups', 'newline': 'VM\nBackups',
                         'quotes': "VM'Backups", 'unicode': 'Sicherungen Grüße'}.items():
    def case(self, root_name=root_name):
        self.check_case(['2026_09_01_00-00-00', '2026_09_02_00-00-00'], 1, ['2026_09_02_00-00-00'], root_name=root_name)
    setattr(RetentionTests, 'test_root_' + label, case)


class BackupFlowTests(unittest.TestCase):
    def check_flow(self, mode, language='de'):
        with tempfile.TemporaryDirectory(prefix='vm-backup-flow-') as temporary:
            root = Path(temporary)
            app, backups, commands = root / 'app', root / 'backups', root / 'bin'
            for directory in [app, backups, commands]:
                directory.mkdir()
            old = backups / '01_01_2000_00-00-00'
            old.mkdir()
            (old / 'sentinel').write_text('EXISTING BACKUP')
            disk = root / 'source.qcow2'
            disk.write_bytes(b'FIXTURE DISK\x00' * 32)
            shutil.copyfile(BACKUP, app / 'vm_backup.sh')
            settings = dict(BACKUP_ROOT=str(backups), LOG_FILE=str(backups / 'backup.log'), VM_DOMAINS='test-vm',
                            STOP_VMS='yes', RESTART_VMS='yes', MAIL_ON='never', MAIL_FORMAT='text', SCRIPT_LANG=language,
                            RETENTION_COUNT='1', LOG_MAX_SIZE_MB='0')
            (app / 'vm_backup.conf').write_text(''.join(key + '=' + shlex.quote(value) + '\n' for key, value in settings.items()))
            stub = commands / 'virsh'
            stub.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$STUB_CALLS"
case "$1" in
  dumpxml) [[ "$STUB_MODE" == xml-fail ]] && exit 1
    echo '<domain><name>test-vm</name><title>Test VM</title></domain>' ;;
  domblklist)
    [[ "$STUB_MODE" == list-fail ]] && exit 1
    [[ "$STUB_MODE" == no-disks ]] && exit 0
    if [[ "$STUB_MODE" == missing-disk ]]; then
      printf 'file disk vda %s.missing\\n' "$STUB_DISK"
    else
      printf 'file disk vda %s\\n' "$STUB_DISK"
    fi ;;
  list) echo test-vm ;;
  domstate) echo 'shut off' ;;
  shutdown|start) exit 0 ;;
  *) exit 2 ;;
esac
''')
            stub.chmod(0o755)
            if mode == 'copy-fail':
                cp = commands / 'cp'
                cp.write_text('#!/usr/bin/env bash\n[[ "${1:-}" == --help ]] && exec /bin/cp --help\nexit 1\n')
                cp.chmod(0o755)
            calls = root / 'calls.log'
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'], STUB_MODE=mode,
                       STUB_DISK=str(disk), STUB_CALLS=str(calls))
            result = subprocess.run(['bash', str(app / 'vm_backup.sh')], env=env, capture_output=True, text=True, timeout=15)
            self.assertIn('shutdown test-vm', calls.read_text())
            self.assertIn('start test-vm', calls.read_text())
            if mode == 'success':
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(old.exists())
                copied = list(backups.glob('*/test-vm/source.qcow2'))
                self.assertEqual(len(copied), 1)
                self.assertEqual(copied[0].read_bytes(), disk.read_bytes())
                self.assertRegex(copied[0].parent.parent.name, r'^\d{4}_\d{2}_\d{2}_\d{2}-\d{2}-\d{2}$')
            else:
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((old / 'sentinel').read_text(), 'EXISTING BACKUP')
                self.assertIn('automatic cleanup skipped' if language == 'en' else 'automatische Bereinigung übersprungen', result.stdout)

for mode in ['success', 'xml-fail', 'list-fail', 'no-disks', 'missing-disk', 'copy-fail']:
    def case(self, mode=mode):
        self.check_flow(mode)
    setattr(BackupFlowTests, 'test_' + mode.replace('-', '_'), case)
for mode in ['success', 'copy-fail']:
    def case(self, mode=mode):
        self.check_flow(mode, 'en')
    setattr(BackupFlowTests, 'test_english_' + mode.replace('-', '_'), case)


class RestoreTests(unittest.TestCase):
    def test_both_directory_formats(self):
        fn = function(RESTORE.read_text(), 'resolve_backup_dir')
        with tempfile.TemporaryDirectory(prefix='vm-restore-test-') as temporary:
            root = Path(temporary)
            for name in ['28_09_2026_12-00-00', '2026_09_28_12-00-00']:
                directory = root / name
                directory.mkdir()
                for argument in [name, str(directory)]:
                    result = subprocess.run(['bash', '-c', 'die() { exit 1; };\n' + fn + '\nresolve_backup_dir "$1"', 'test', argument],
                                            env=dict(os.environ, BACKUP_ROOT=str(root)), capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), str(directory.resolve()))

    def test_help_in_both_languages(self):
        with tempfile.TemporaryDirectory(prefix='vm-restore-help-') as temporary:
            config = Path(temporary) / 'test.conf'
            for language, expected in [('de', 'Beispiele:'), ('en', 'Examples:')]:
                config.write_text('SCRIPT_LANG=' + language + '\n')
                result = subprocess.run(['bash', str(RESTORE), '--config', str(config), '--help'], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
