# Changelog

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
