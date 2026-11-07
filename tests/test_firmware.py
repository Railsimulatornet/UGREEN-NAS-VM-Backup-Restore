"""UEFI state is part of a stopped VM, not a substitute for its guest disk."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from test_retention import function

ROOT = Path(__file__).resolve().parents[1]
BACKUP = Path(os.environ.get('VM_BACKUP_SOURCE', ROOT / 'VMBackup/vm_backup.sh')).read_text()
RESTORE = Path(os.environ.get('VM_RESTORE_SOURCE', ROOT / 'VMBackup/vm_restore.sh')).read_text()


class FirmwareTests(unittest.TestCase):
    def test_backup_saves_nvram(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            nvram = root / 'original vars.fd'
            nvram.write_bytes(b'UEFI_BOOT_ENTRY_AND_VARIABLES')
            nvram.chmod(0o600)
            xml = root / 'vm.xml'
            xml.write_text(f'<domain><os><nvram template="default.fd">{nvram}</nvram></os></domain>')
            code = 'log(){ :; };\n' + function(BACKUP, 'backup_vm_nvram') + '\nbackup_vm_nvram "$1" "$2"\n'
            p = subprocess.run(['bash', '-c', code, 'test', str(xml), str(root)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual((root / 'nvram.fd').read_bytes(), nvram.read_bytes())
            self.assertEqual((root / 'nvram.fd').stat().st_mode, nvram.stat().st_mode)

    def test_missing_required_nvram_fails_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            xml = root / 'vm.xml'
            xml.write_text(f'<domain><os><nvram>{root}/missing.fd</nvram></os></domain>')
            code = 'log(){ :; };\n' + function(BACKUP, 'backup_vm_nvram') + '\nbackup_vm_nvram "$1" "$2"\n'
            p = subprocess.run(['bash', '-c', code, 'test', str(xml), str(root)], capture_output=True, text=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertFalse((root / 'nvram.fd').exists())

    def prepare_case(self, firmware=True, dry=False, bios=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'target'
            target.mkdir()
            saved = root / 'nvram.fd'
            if firmware:
                saved.write_bytes(b'ORIGINAL_BOOT_ORDER')
            xml = root / 'backup.xml'
            nvram = '' if bios else '<nvram template="template.fd">/old/NVRAM.fd</nvram>'
            xml.write_text('<domain><name>UGOS-name</name><uuid>original-libvirt-uuid</uuid>'
                '<os>'+nvram+'</os><devices>'
                '<disk device="disk"><source file="/old/disk.qcow2"/></disk>'
                '<disk device="cdrom"><source file="/iso/installer.iso"/></disk>'
                '</devices></domain>')
            output = root / 'restored.xml'
            code = 'set -euo pipefail\n' + function(RESTORE, 'prepare_dr_xml') + '\nprepare_dr_xml "$1" "$2" "$3"\n'
            env = dict(os.environ, VM_BACKUP_DIR=str(root), DRY_RUN='1' if dry else '0')
            p = subprocess.run(['bash', '-c', code, 'test', str(xml), str(output), str(target)],
                               env=env, capture_output=True, text=True)
            if not firmware and not bios:
                self.assertNotEqual(p.returncode, 0)
                self.assertFalse(output.exists())
                self.assertEqual(list(target.iterdir()), [])
                return
            self.assertEqual(p.returncode, 0, p.stderr)
            if dry:
                self.assertFalse(output.exists())
                self.assertEqual(list(target.iterdir()), [])
                return
            restored = ET.parse(output).getroot()
            self.assertEqual(restored.findtext('uuid'), 'original-libvirt-uuid')
            self.assertEqual(restored.find('./devices/disk[@device="cdrom"]/source').get('file'), '/iso/installer.iso')
            self.assertEqual(restored.find('./devices/disk[@device="disk"]/source').get('file'), str(target / 'disk.qcow2'))
            if not bios:
                self.assertEqual(restored.findtext('./os/nvram'), str(target / 'nvram.fd'))
                self.assertEqual((target / 'nvram.fd').read_bytes(), saved.read_bytes())

    def test_restore_preserves_uuid_and_iso_and_recovers_firmware(self):
        self.prepare_case()

    def test_uefi_backup_without_firmware_fails_closed(self):
        self.prepare_case(firmware=False)

    def test_bios_archives_remain_supported(self):
        self.prepare_case(firmware=False, bios=True)

    def test_dry_run_does_not_copy_or_change_firmware(self):
        self.prepare_case(dry=True)

    def test_existing_vm_firmware_restore_and_dry_run(self):
        for dry in ('0', '1'):
            with self.subTest(dry=dry), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                saved = root / 'nvram.fd'
                saved.write_bytes(b'SAVED_BOOT_STATE')
                destination = root / 'current vars.fd'
                destination.write_bytes(b'CURRENT_BOOT_STATE')
                xml = root / 'current.xml'
                xml.write_text(f'<domain><os><nvram>{destination}</nvram></os></domain>')
                code = '''set -euo pipefail
log(){ :; }
virsh(){ cat "$CURRENT_XML"; }
run(){ eval "$1"; }
die(){ printf '%s' "$*" >&2; exit 1; }
''' + function(RESTORE, 'restore_existing_nvram') + '\nrestore_existing_nvram\n'
                env = dict(os.environ, VM_BACKUP_DIR=str(root), TMP_WORK_DIR=str(root / 'temporary'),
                           DOMAIN_UUID='existing-domain', DRY_RUN=dry, CURRENT_XML=str(xml))
                p = subprocess.run(['bash', '-c', code], env=env, capture_output=True, text=True)
                self.assertEqual(p.returncode, 0, p.stderr)
                expected = b'CURRENT_BOOT_STATE' if dry == '1' else saved.read_bytes()
                self.assertEqual(destination.read_bytes(), expected)
                if dry == '1':
                    self.assertFalse((root / 'temporary').exists())
