"""A dry-run shutdown must neither wait for nor interrupt a real running guest."""
import os
import subprocess
import unittest
from test_retention import RESTORE, function


class RestoreShutdownTests(unittest.TestCase):
    def invoke(self, dry):
        code = '''set -Eeuo pipefail
log(){ :; }
virsh(){ [[ "$1" == dominfo ]]; }
get_dom_state(){ printf running; }
run(){ printf 'COMMAND:%s\\n' "$1"; }
sleep(){ printf 'UNEXPECTED_WAIT\\n'; exit 90; }
die(){ printf '%s' "$*" >&2; exit 1; }
''' + function(RESTORE.read_text(), 'shutdown_vm') + '\nshutdown_vm actual-domain\n'
        return subprocess.run(['bash', '-c', code], capture_output=True, text=True,
                              env=dict(os.environ, DRY_RUN=dry, SHUTDOWN_TIMEOUT='0', FORCE_STOP='0'), timeout=5)

    def test_dry_run_does_not_wait_for_running_vm(self):
        p = self.invoke('1')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('COMMAND:virsh shutdown', p.stdout)
        self.assertNotIn('UNEXPECTED_WAIT', p.stdout)
        self.assertNotIn('destroy', p.stdout)

    def test_real_restore_still_rejects_a_vm_that_did_not_stop(self):
        p = self.invoke('0')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('VM läuft noch', p.stderr)
