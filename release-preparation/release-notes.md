## UGREEN VM Backup & Restore v4.0.1

VM Backup & Restore package for UGREEN NAS virtual machines.

### Features
- VM backup via bash
- Normal restore
- Disaster Recovery (DR)
- VNC/share-link repair
- Cronjob support
- E-mail notifications
- German & English documentation

### Fixed in v4.0.1
- Correct retention sorting across month and year boundaries.
- New backup folders use `YYYY_MM_DD_HH-MM-SS`; existing `DD_MM_YYYY_HH-MM-SS` folders remain supported.
- Keep existing backups when the current backup fails, including disk-list and copy errors.
- Validate calendar dates, times and retention counts before cleanup.
- Preserve paths containing whitespace or line breaks; ignore symlinks and unrelated directories.
- Return a non-zero exit status for failed backups.
- Added 32 regression tests, including stubbed backup runs and restore path compatibility.

Thanks to Ghent for reporting the retention issue. :-)

### Included
- `VMBackup/vm_backup.sh`
- `VMBackup/vm_restore.sh`
- `VMBackup/vm_backup.conf`
- PDF manual (V4.0, unchanged)
- README, changelog and disclaimer are available in the repository.

### Notes
- The ZIP file is provided as the release package, with the same folder layout as v4.0.
- The repository contains the scripts and documentation.
- When upgrading, keep your own `vm_backup.conf`; do not overwrite it with the example configuration.
- `vm_restore.sh` and the V4.0 manual are unchanged. Use the actual backup folder name when restoring.
- VMs without file-backed disks are reported as backup errors; automatic cleanup is skipped.
- Tests use temporary fixtures and stubbed `virsh` calls. A live restore on UGREEN hardware was not performed.
- This draft is awaiting review and merge of the additional release-safety fixes. It has not been published.
- After extracting on the NAS, set executable permissions:
  `chmod +x /volume1/VMBackup/*.sh`

### Standard path on the NAS
`/volume1/VMBackup`

Use at your own risk.
