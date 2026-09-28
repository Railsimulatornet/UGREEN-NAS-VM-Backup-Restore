# Changelog

## V4.0.1 - 2026-09-28

### Fixes

- changed backup directory timestamps to the chronologically sortable format `YYYY_MM_DD_HH-MM-SS`
- fixed retention sorting across month and year boundaries
- cleanup now only considers recognized backup directory names
- legacy `DD_MM_YYYY_HH-MM-SS` backup directories remain supported and are normalized for retention sorting
- skip retention after a failed backup; failed runs now return exit status 1
- treat failed disk enumeration and VMs without file-backed disks as backup errors instead of silently pruning previous backups
- validate calendar dates (including leap years), times and retention counts before deleting anything
- preserve paths containing whitespace, quotes or line breaks; ignore symbolic links and unrelated directories
- added 32 regression tests covering retention, stubbed backup flows and restore path compatibility
- thanks to Ghent for reporting the issue

## V4.0 - 2026-04-15

Final release package for:

- `vm_backup.sh`
- `vm_restore.sh`
- `vm_backup.conf`

### Highlights

- shared German / English configuration via `SCRIPT_LANG`
- VM backup with timestamped directories
- restore of qcow2 disks to existing VMs
- Disaster Recovery workflow for missing VMs
- automatic DB registration during DR
- VNC / share-link repair workflow
- VNC guard with early exit after stable link detection
- HTML / text notification emails
- bilingual handbook (DE / EN)

### Notes

- standard package directory: `/volume1/VMBackup`
- after extracting the ZIP on UGOS/Linux, run:
  ```bash
  chmod +x vm_backup.sh vm_restore.sh
  ```
