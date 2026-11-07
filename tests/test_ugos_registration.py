"""Exercise registration against real SQLite schemas, without changing a host VM."""
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from test_retention import function

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('VM_RESTORE_SOURCE', ROOT / 'VMBackup/vm_restore.sh')).read_text()
FUNCTIONS = '\n'.join(function(SOURCE, n) for n in (
    'sqlite_table_exists', 'sqlite_col_exists', 'sqlite_col_count',
    'sqlite_insert_link_row', 'guess_os_type', 'db_register_vm', 'vnc_guard'))
HELPERS = '''
set -euo pipefail
IFS=$'\\n\\t'
log() { printf '%s\\n' "$*"; }
die() { log "$*"; return 1; }
have_cmd() { command -v "$1" >/dev/null; }
run() { eval "$1"; }
find_vm_db_by_storage_path() { printf '%s' "$TEST_DB"; }
find_vm_db() { printf '%s' "$TEST_DB"; }
get_current_disk_paths() { printf '/volume1/@kvm/fixture/disk.qcow2'; }
restart_vm_services() { :; }
vnc_fix_final() { :; }
s3_exec() { sqlite3 "$1" "$2"; }
s3_out() { sqlite3 "$1" "$2"; }
sleep() { :; }
'''


class UgOSRegistrationTests(unittest.TestCase):
    def scenario(self, modern=True, extra=False, override=''):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'vm.db'
            c = sqlite3.connect(db)
            state = 'processState' if modern else 'status'
            path = 'path' if modern else 'storagePath'
            extra_sql = ', guestToolStatus INTEGER NOT NULL DEFAULT 0' if extra else ''
            c.executescript(f'''
                CREATE TABLE virtual_machine(id INTEGER PRIMARY KEY, virName TEXT,
                  displayName TEXT, osType TEXT, systemVersion TEXT, {state} TEXT,
                  autoStart INTEGER NOT NULL, create_time INTEGER NOT NULL {extra_sql});
                CREATE TABLE virtual_machine_bind(id INTEGER PRIMARY KEY,
                  storageUUID TEXT, storageName TEXT, {path} TEXT, virName TEXT);
                CREATE TABLE storage(id INTEGER PRIMARY KEY, path TEXT, uuid TEXT);
                INSERT INTO storage VALUES(1,'/volume1','storage-fixture');
                CREATE TABLE virtual_machine_link(id INTEGER PRIMARY KEY, virName TEXT,
                  passwd TEXT DEFAULT '',vncPort INTEGER DEFAULT 0,noVncPort INTEGER DEFAULT 0,
                  disableLink INTEGER DEFAULT 0,type INTEGER DEFAULT 0,apiKey TEXT DEFAULT '',
                  encryptedVersion INTEGER DEFAULT 0);
                INSERT INTO virtual_machine VALUES(99,'unselected','keep','linux','keep','keep',1,1 {',0' if extra else ''});
            ''')
            c.commit()
            original = c.execute("SELECT * FROM virtual_machine WHERE id=99").fetchone()
            env = dict(os.environ, TEST_DB=str(db), DOMAIN_UUID='fixture', DOMAIN_NAME='fixture',
                VM_ARG='relay-lab', XML_TITLE='relay-lab', VM_EXISTS_IN_LIBVIRT='1',
                DISPLAY_NAME_OVERRIDE='', OS_TYPE_OVERRIDE=override, SYSTEM_VERSION_OVERRIDE='',
                DR_MODE='1', RESET_LINK='1')
            code = HELPERS + FUNCTIONS + '\ndb_register_vm\ndb_register_vm\n'
            p = subprocess.run(['bash', '-c', code], env=env, capture_output=True,
                               text=True, timeout=20)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertEqual(c.execute("SELECT count(*) FROM virtual_machine WHERE virName='fixture'").fetchone()[0], 1)
            self.assertEqual(c.execute("SELECT osType FROM virtual_machine WHERE virName='fixture'").fetchone()[0], override or 'linux')
            self.assertEqual(c.execute(f"SELECT {state} FROM virtual_machine WHERE virName='fixture'").fetchone()[0], 'createSuccess')
            self.assertEqual(c.execute(f"SELECT {path} FROM virtual_machine_bind WHERE virName='fixture'").fetchone()[0], '/volume1')
            self.assertEqual(c.execute("SELECT count(*) FROM virtual_machine_bind WHERE virName='fixture'").fetchone()[0], 1)
            self.assertEqual(c.execute("SELECT count(*) FROM virtual_machine_link WHERE virName='fixture'").fetchone()[0], 1)
            self.assertEqual(c.execute("SELECT * FROM virtual_machine WHERE id=99").fetchone(), original)
            c.close()

    def test_current_nine_column_schema_and_linux_type(self):
        self.scenario(modern=True, extra=True)

    def test_current_eight_column_schema(self):
        self.scenario(modern=True)

    def test_legacy_status_and_storage_path(self):
        self.scenario(modern=False)

    def test_explicit_windows_override(self):
        self.scenario(modern=True, extra=True, override='windows')

    def test_vnc_trace_never_logs_password(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'link.db'
            c = sqlite3.connect(db)
            c.executescript('''CREATE TABLE virtual_machine_link(id INTEGER PRIMARY KEY,
                virName TEXT,passwd TEXT,vncPort INTEGER,noVncPort INTEGER,disableLink INTEGER,
                type INTEGER,apiKey TEXT,encryptedVersion INTEGER);
                INSERT INTO virtual_machine_link VALUES(1,'fixture','PRIVATE_GUARD_SECRET',5901,6081,0,0,'key',0);''')
            c.commit()
            env = dict(os.environ, TEST_DB=str(db), TRACE_LINK='1', NO_VNC_GUARD='0',
                       VNC_GUARD_RESET_PORTS='0')
            p = subprocess.run(['bash', '-c', HELPERS + FUNCTIONS + '\nvnc_guard "$TEST_DB" fixture 2\n'],
                               env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertNotIn('PRIVATE_GUARD_SECRET', p.stdout + p.stderr)
            self.assertIn('[redacted]', p.stdout)
            c.close()
