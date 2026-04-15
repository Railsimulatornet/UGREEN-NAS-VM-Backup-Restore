#!/usr/bin/env bash
# vm_restore.sh - UGREEN NAS VM Restore incl. Disaster Recovery (DR) v4.0
# Copyright (c) 2026 Roman Glos for Ugreen NAS Community
# For UGREEN VM App / com.ugreen.kvm
# License: use at your own risk

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------
# Defaults / Pfade
# -----------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/vm_backup.conf"

# Runtime-Flags
DR_MODE=0
REGISTER_DB=0
RESET_LINK=0
FORCE_STOP=0
SHUTDOWN_TIMEOUT=180
TARGET_VOLUME=""
RESTORE_XML=1
DRY_RUN=0
NO_START=0
FORCE_START=0
OS_TYPE_OVERRIDE=""
SYSTEM_VERSION_OVERRIDE=""
NO_SERVICE_RESTART=0

# VNC/UI Guard
VNC_GUARD_SECS=180   # läuft nach Restore für X Sekunden und hält virtual_machine_link "neutral"
NO_VNC_GUARD=0       # 1=deaktiviert Guard
TRACE_LINK=0         # 1=loggt Link-State während Guard
VNC_GUARD_RESET_PORTS=0  # 1=VNC-Guard setzt zusätzlich vncPort/noVncPort auf 0
VNC_GUARD_EARLY_EXIT=1   # 1=Guard endet vorzeitig, sobald Link einige Zyklen stabil ist
VNC_GUARD_STABLE_HITS=3  # Anzahl stabiler Good-State-Zyklen bis Early-Exit

VM_ARG=""
BACKUP_ARG=""
LOG_FILE=""
VM_DB=""
TMP_WORK_DIR="${SCRIPT_DIR}/.vm_restore_tmp"
SCRIPT_LANG="de"

# -----------------------------
# Helper
# -----------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }

normalize_lang() {
  case "${SCRIPT_LANG:-de}" in
    en|EN|english|English) SCRIPT_LANG="en" ;;
    *) SCRIPT_LANG="de" ;;
  esac
}

translate_restore_msg() {
  local msg="$*"
  [[ "${SCRIPT_LANG:-de}" == "en" ]] || { printf '%s' "$msg"; return; }

  case "$msg" in
    "Starte vm_restore.sh") printf 'Starting vm_restore.sh'; return ;;
    "Restore: qcow2 zurückspielen") printf 'Restore: restoring qcow2 disks'; return ;;
    "Restore: qcow2 fertig.") printf 'Restore: qcow2 restore finished.'; return ;;
    "DB-Register: fertig.") printf 'DB registration: finished.'; return ;;
    "VNC-Guard: beendet.") printf 'VNC guard: finished.'; return ;;
    "DB: virtual_machine fehlt -> Insert") printf 'DB: virtual_machine missing -> insert'; return ;;
    "DB: Lege virtual_machine_bind an.") printf 'DB: creating virtual_machine_bind.'; return ;;
    "DB: virtual_machine_bind existiert bereits.") printf 'DB: virtual_machine_bind already exists.'; return ;;
    "DB: virtual_machine existiert -> Update") printf 'DB: virtual_machine exists -> update'; return ;;
    "DB: virtual_machine_link fehlt -> lege Basiszeile an.") printf 'DB: virtual_machine_link missing -> creating base row.'; return ;;
    "DB: Normalize osType/systemVersion (reset-link).") printf 'DB: normalize osType/systemVersion (reset-link).'; return ;;
    "DB: Neutralize virtual_machine_link (reset-link).") printf 'DB: neutralize virtual_machine_link (reset-link).'; return ;;
    "DB: Re-Apply virtual_machine_link Neutral-Update (post-service-restart).") printf 'DB: re-apply virtual_machine_link neutral update (post service restart).'; return ;;
    "DB: Final VNC Fix (post-worker).") printf 'DB: final VNC fix (post-worker).'; return ;;
    "DB: Final VNC Fix (post-start).") printf 'DB: final VNC fix (post-start).'; return ;;
    "Service-Restart: KVM/Libvirt/UGREEN VM Dienste neu starten (best effort).") printf 'Service restart: restarting KVM/Libvirt/UGREEN VM services (best effort).'; return ;;
    "Service-Restart: übersprungen (--no-service-restart).") printf 'Service restart: skipped (--no-service-restart).'; return ;;
    "VNC-Guard: Bitte jetzt in UGOS diese Schritte ausführen:") printf 'VNC guard: please perform these steps in UGOS now:'; return ;;
    "VNC-Guard: 1) VM öffnen und auf den Reiter 'Freigabe' gehen.") printf "VNC guard: 1) Open the VM and go to the 'Share' tab."; return ;;
    "VNC-Guard: 2) '+ Hinzufügen' bzw. 'Freigabelink erstellen' anklicken.") printf "VNC guard: 2) Click '+ Add' or 'Create share link'."; return ;;
    "VNC-Guard: 3) Zugriffsmethode wählen (meist 'LAN').") printf "VNC guard: 3) Choose the access method (usually 'LAN')."; return ;;
    "VNC-Guard: 4) Falls ein Link angezeigt wird: optional kopieren, dann auf 'Bestätigen' klicken.") printf "VNC guard: 4) If a link is shown, you can copy it, then click 'Confirm'."; return ;;
    "VNC-Guard: 5) Im Freigabe-Fenster unten auf 'Übernehmen' klicken.") printf "VNC guard: 5) In the share window, click 'Apply' at the bottom."; return ;;
    "VNC-Guard: 6) Fenster schließen und danach auf der VM-Übersicht auf 'Verbinden' klicken.") printf "VNC guard: 6) Close the window and then click 'Connect' on the VM overview."; return ;;
  esac

  case "$msg" in
    VM-Argument:*) printf 'VM argument: %s' "${msg#VM-Argument: }"; return ;;
    Backup-Argument:*) printf 'Backup argument: %s' "${msg#Backup-Argument: }"; return ;;
    Config:*) printf 'Config: %s' "${msg#Config: }"; return ;;
    Backup-Dir:*) printf 'Backup dir: %s' "${msg#Backup-Dir: }"; return ;;
    Backup-XML\ Title:*) printf 'Backup XML title: %s' "${msg#Backup-XML Title: }"; return ;;
    Backup-XML:*) printf 'Backup XML: %s' "${msg#Backup-XML: }"; return ;;
    Backup-Disks:*) printf 'Backup disks: %s' "${msg#Backup-Disks: }"; return ;;
    DRY-RUN:\ würde\ fehlendes\ KVM-Root\ anlegen:*) printf 'DRY-RUN: would create missing KVM root: %s' "${msg#DRY-RUN: würde fehlendes KVM-Root anlegen: }"; return ;;
    DR:\ KVM-Root\ fehlt\ auf\ Ziel-Volume\ \-\>\ lege\ an:*) printf 'DR: KVM root is missing on target volume -> creating: %s' "${msg#DR: KVM-Root fehlt auf Ziel-Volume -> lege an: }"; return ;;
    Restore:\ virsh\ define\ aus\ Backup-XML) printf 'Restore: virsh define from backup XML'; return ;;
    Restore:\ VM\ existiert\ bereits\ in\ Libvirt*) printf 'Restore: VM already exists in libvirt -> skipping virsh define. Delete the VM and use --dr for a full re-define from backup XML.'; return ;;
    VM\ wird\ NICHT\ gestartet*) printf 'VM will NOT be started (--no-start).'; return ;;
    VM\ bleibt\ aus*) printf 'VM stays powered off (it was off before). Use --start to start it.'; return ;;
    Starte\ VM:*) printf 'Starting VM: %s' "${msg#Starte VM: }"; return ;;
    DR:\ Kopiere\ qcow2\ nach*) printf 'DR: copying qcow2 to %s' "${msg#DR: Kopiere qcow2 nach }"; return ;;
    FERTIG.*) printf "DONE. Note: If 'Connect' or the console does not appear immediately, reload the VM app/browser tab and confirm/apply the share link again in the UI."; return ;;
  esac

  if [[ "$msg" == "VM-Auflösung aus Backup: Eingabe '"* ]]; then
    local parsed
    parsed="$(printf '%s' "$msg" | sed -n "s/^VM-Auflösung aus Backup: Eingabe '\\([^']*\\)' -> virName '\\([^']*\\)' (Title: \\(.*\\))$/\1|\2|\3/p")"
    if [[ -n "$parsed" ]]; then
      local input_name vir_name title_name
      IFS='|' read -r input_name vir_name title_name <<< "$parsed"
      printf "VM resolved from backup: input '%s' -> virName '%s' (title: %s)" "$input_name" "$vir_name" "$title_name"
      return
    fi
    parsed="$(printf '%s' "$msg" | sed -n "s/^VM-Auflösung aus Backup: Eingabe '\\([^']*\\)' -> virName '\\([^']*\\)'$/\1|\2/p")"
    if [[ -n "$parsed" ]]; then
      local input_name vir_name
      IFS='|' read -r input_name vir_name <<< "$parsed"
      printf "VM resolved from backup: input '%s' -> virName '%s'" "$input_name" "$vir_name"
      return
    fi
  elif [[ "$msg" == "VM-Auflösung aus libvirt: Eingabe '"* ]]; then
    local parsed
    parsed="$(printf '%s' "$msg" | sed -n "s/^VM-Auflösung aus libvirt: Eingabe '\\([^']*\\)' -> virName '\\([^']*\\)'$/\1|\2/p")"
    if [[ -n "$parsed" ]]; then
      local input_name vir_name
      IFS='|' read -r input_name vir_name <<< "$parsed"
      printf "VM resolved from libvirt: input '%s' -> virName '%s'" "$input_name" "$vir_name"
      return
    fi
  elif [[ "$msg" == "WARN: shutdown_vm ohne DOM_REF -> skip." ]]; then
    printf 'WARN: shutdown_vm without DOM_REF -> skip.'; return
  elif [[ "$msg" == "VNC-Guard: vm.db unbekannt -> skip." ]]; then
    printf 'VNC guard: vm.db unknown -> skip.'; return
  fi

  if [[ "$msg" =~ ^ERROR:\ Unbekannte\ Option:\ (.+)$ ]]; then
    printf 'ERROR: Unknown option: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ Zu\ viele\ Parameter:\ (.+)$ ]]; then
    printf 'ERROR: Too many parameters: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ virsh\ nicht\ gefunden\.$ ]]; then
    printf 'ERROR: virsh not found.'; return
  elif [[ "$msg" =~ ^WARN:\ sqlite3\ nicht\ gefunden ]]; then
    printf 'WARN: sqlite3 not found - DB registration may fail.'; return
  elif [[ "$msg" =~ ^ERROR:\ rsync\ nicht\ gefunden\.$ ]]; then
    printf 'ERROR: rsync not found.'; return
  elif [[ "$msg" =~ ^ERROR:\ Backup-Verzeichnis\ nicht\ gefunden:\ (.+)$ ]]; then
    printf 'ERROR: Backup directory not found: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ Konnte\ VM/UUID\ nicht\ bestimmen\..*$ ]]; then
    printf 'ERROR: Could not determine the VM/UUID. Please specify the VM title, virName, or UUID.'; return
  elif [[ "$msg" =~ ^ERROR:\ VM-Backup-Ordner\ nicht\ gefunden:\ (.+)$ ]]; then
    printf 'ERROR: VM backup directory not found: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ Kein\ XML\ im\ Backup\ gefunden:\ (.+)$ ]]; then
    printf 'ERROR: No XML file found in backup: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ Keine\ qcow2\ im\ Backup\ gefunden:\ (.+)$ ]]; then
    printf 'ERROR: No qcow2 files found in backup: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VM\ ist\ in\ Libvirt\ derzeit\ nicht\ vorhanden\ \(dom=(.+)\)\ \-\>\ shutdown\ übersprungen\.$ ]]; then
    printf 'VM is currently not present in libvirt (dom=%s) -> shutdown skipped.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VM\ läuft\ \-\>\ shutdown:\ (.+)$ ]]; then
    printf 'VM is running -> shutdown: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VM\ ist\ aus\ \(state=(.+)\)$ ]]; then
    printf 'VM is powered off (state=%s)' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARN:\ shutdown\ Timeout\ erreicht\ \(state=(.+)\)$ ]]; then
    printf 'WARN: shutdown timeout reached (state=%s)' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^Force-Stop:\ virsh\ destroy\ (.+)$ ]]; then
    printf 'Force stop: virsh destroy %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ VM\ hängt\ weiterhin\ \(state=(.+)\)$ ]]; then
    printf 'ERROR: VM is still hanging (state=%s)' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ VM\ läuft\ noch\..*$ ]]; then
    printf 'ERROR: VM is still running. Use --force-stop or increase --shutdown-timeout.'; return
  elif [[ "$msg" =~ ^VM\ läuft\ nicht\ \(state=(.+)\)$ ]]; then
    printf 'VM is not running (state=%s)' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^DR:\ VM\ existiert\ nicht\ in\ Libvirt\ \-\>\ define\ aus\ Backup-XML$ ]]; then
    printf 'DR: VM does not exist in libvirt -> define from backup XML'; return
  elif [[ "$msg" =~ ^ERROR:\ DR:\ Konnte\ target\ volume\ nicht\ bestimmen\..*$ ]]; then
    printf 'ERROR: DR: could not determine target volume. Please set --target-volume /volume2.'; return
  elif [[ "$msg" =~ ^ERROR:\ DR:\ Target\ volume\ existiert\ nicht:\ (.+)$ ]]; then
    printf 'ERROR: DR: target volume does not exist: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ DR:\ Konnte\ KVM-Root\ nicht\ anlegen:\ (.+)$ ]]; then
    printf 'ERROR: DR: could not create KVM root: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^DR:\ DRY-RUN\ vorbereitet\.\ Domain-Name\ laut\ XML:\ (.+)$ ]]; then
    printf 'DR: dry-run prepared. Domain name from XML: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^DR:\ virsh\ define\ ok\.\ Domain-Name:\ (.+)$ ]]; then
    printf 'DR: virsh define successful. Domain name: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ DR:\ virsh\ define\ fehlgeschlagen:\ (.+)$ ]]; then
    printf 'ERROR: DR: virsh define failed: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^DB:\ Link-Ports\ bereit\ \(vncPort=(.+),\ noVncPort=(.+)\)\.$ ]]; then
    printf 'DB: link ports ready (vncPort=%s, noVncPort=%s).' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^WARN:\ systemctl\ nicht\ vorhanden\ \-\>\ skip\ Service-Restart\.$ ]]; then
    printf 'WARN: systemctl not found -> skipping service restart.'; return
  elif [[ "$msg" =~ ^DB:\ VNC-Watchdog\ läuft\ ([0-9]+)s\ im\ Hintergrund\ \(auto-neutralize\)\.$ ]]; then
    printf 'DB: VNC watchdog is running in the background for %ss (auto-neutralize).' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VNC-Guard:\ aktiv\ für\ ([0-9]+)s\.$ ]]; then
    printf 'VNC guard: active for %ss.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VNC-Guard:\ Row\ fehlt\ \-\>\ Re-Insert\ \(best\ effort\)\.$ ]]; then
    printf 'VNC guard: row missing -> re-insert (best effort).'; return
  elif [[ "$msg" =~ ^VNC-Guard:\ state=(.+)$ ]]; then
    printf 'VNC guard: state=%s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VNC-Guard:\ stabiler\ Link\ erkannt\ \(hits=([0-9]+),\ vncPort=([0-9]+),\ noVncPort=([0-9]+)\)\ \-\>\ beende\ Guard\ vorzeitig\.$ ]]; then
    printf 'VNC guard: stable link detected (hits=%s, vncPort=%s, noVncPort=%s) -> stopping guard early.' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; return
  elif [[ "$msg" =~ ^WARN:\ vm\.db\ nicht\ gefunden\ \-\>\ skip\ DB-Register\.$ ]]; then
    printf 'WARN: vm.db not found -> skipping DB registration.'; return
  elif [[ "$msg" =~ ^WARN:\ storage\.uuid\ konnte\ nicht\ bestimmt\ werden\..*$ ]]; then
    printf 'WARN: storage.uuid could not be determined. virtual_machine_bind may not work.'; return
  elif [[ "$msg" =~ ^WARN:\ Tabelle\ virtual_machine\ nicht\ gefunden\.$ ]]; then
    printf 'WARN: table virtual_machine not found.'; return
  elif [[ "$msg" =~ ^DB:\ virtual_machine_link\ vorhanden\..*$ ]]; then
    printf 'DB: virtual_machine_link exists. If the UI VNC console still does not work: open the VM card and click console/VNC once so ports/token are regenerated.'; return
  elif [[ "$msg" =~ ^ERROR:\ VM\ existiert\ nicht\ in\ Libvirt\.\ Nutze\ \-\-dr\ für\ Disaster\ Recovery\.$ ]]; then
    printf 'ERROR: VM does not exist in libvirt. Use --dr for disaster recovery.'; return
  elif [[ "$msg" =~ ^DR:\ VM\ wurde\ bereits\ definiert\ \(skip\ redefine\)\.$ ]]; then
    printf 'DR: VM was already defined (skip redefine).'; return
  elif [[ "$msg" =~ ^DR:\ Definiere\ VM\ aus\ Backup-XML\ \(Pfad-Rewrite\ \+\ QCOW2\ nach\ Ziel-@kvm\)$ ]]; then
    printf 'DR: defining VM from backup XML (path rewrite + QCOW2 to target @kvm)'; return
  elif [[ "$msg" =~ ^WARN:\ Konnte\ Disk-Pfade\ via\ dumpxml\ nicht\ lesen\.\ DR-Fallback:\ suche\ unter\ /volume\*/@kvm/(.+)$ ]]; then
    printf 'WARN: could not read disk paths via dumpxml. DR fallback: searching under /volume*/@kvm/%s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^ERROR:\ DR:\ Konnte\ KVM_ROOT\ nicht\ bestimmen\..*$ ]]; then
    printf 'ERROR: DR: could not determine KVM_ROOT. Expected: /volume1..4/@kvm exists.'; return
  elif [[ "$msg" =~ ^DRY-RUN:\ würde\ Zielverzeichnis\ anlegen:\ (.+)$ ]]; then
    printf 'DRY-RUN: would create target directory: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^DR:\ Ziel-Disks\ aus\ Backup\ abgeleitet:\ ([0-9]+)\ \(Target=(.+)\)$ ]]; then
    printf 'DR: target disks derived from backup: %s (target=%s)' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^ERROR:\ Keine\ Ziel-qcow2\ gefunden\.$ ]]; then
    printf 'ERROR: No target qcow2 files found.'; return
  elif [[ "$msg" =~ ^WARN:\ Kein\ Basename-Match\ für\ (.+)\ \-\>\ nutze\ einzige\ Disk:\ (.+)$ ]]; then
    printf 'WARN: no basename match for %s -> using the only disk: %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^ERROR:\ Konnte\ Ziel-Disk\ für\ (.+)\ nicht\ finden\..*$ ]]; then
    printf 'ERROR: Could not find target disk for %s. XML/backup does not match the VM.' "${BASH_REMATCH[1]}"; return
  fi

  printf '%s' "$msg"
}

log() {
  local msg
  msg="$(translate_restore_msg "$*")"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s - %s
' "$(ts)" "$msg" | tee -a "$LOG_FILE"
  else
    printf '%s - %s
' "$(ts)" "$msg"
  fi
}

cleanup_tmp() {
  if [[ -n "${TMP_WORK_DIR:-}" && -d "${TMP_WORK_DIR:-}" ]]; then
    rm -rf -- "${TMP_WORK_DIR:?}" 2>/dev/null || true
  fi
}

err_trap() {
  local ec=$?
  if [[ "${SCRIPT_LANG:-de}" == "en" ]]; then
    printf '%s - ERROR: Script aborted (exit=%s) at line %s: %s
' "$(date '+%Y-%m-%d %H:%M:%S')" "$ec" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
  else
    printf '%s - ERROR: Script-Abbruch (exit=%s) in Zeile %s: %s
' "$(date '+%Y-%m-%d %H:%M:%S')" "$ec" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
  fi
  exit "$ec"
}
trap err_trap ERR
trap cleanup_tmp EXIT

die() { log "ERROR: $*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# sqlite helper (reduces "database is locked"/hangs)
s3_out() {
  local db="$1" sql="$2"
  sqlite3 -cmd ".timeout 5000" "$db" "$sql" 2>/dev/null || true
}
s3_exec() {
  local db="$1" sql="$2"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log "DRY-RUN: sqlite3 '$db' \"$sql\""
    return 0
  fi
  sqlite3 -cmd ".timeout 5000" "$db" "$sql" 2>/dev/null || true
}
run() {
  # DRY_RUN wrapper
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  eval "$@"
}

is_uuid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

usage() {
  if [[ "${SCRIPT_LANG:-de}" == "en" ]]; then
    cat <<'USAGE'
Usage:
  vm_restore.sh [options] <VM> <BACKUP_DIR>
  vm_restore.sh [options] <BACKUP_DIR> <VM>          (order does not matter)

Examples:
  ./vm_restore.sh Win2022 /volume2/VMBackup/04_12_2025_15-29-47
  ./vm_restore.sh /volume2/VMBackup/04_12_2025_15-29-47 Win2022
  ./vm_restore.sh 128cea77-77a0-4cb9-b4e0-1434d0feb2a6 /volume2/VMBackup/04_12_2025_15-29-47

Disaster Recovery (if the VM no longer exists in the VM app/libvirt):
  ./vm_restore.sh --dr Win2022 /volume2/VMBackup/04_12_2025_15-29-47
  ./vm_restore.sh --dr 128cea77-77a0-4cb9-b4e0-1434d0feb2a6 /volume2/VMBackup/04_12_2025_15-29-47

Options:
  --config <path>           Config file (default: ./vm_backup.conf)
  --dr                      Disaster recovery: define VM from backup XML + copy disks + register DB
                            Also enables automatically: --register-db --reset-link --vnc-guard <default> --trace-link
  --register-db             Run DB registration only (virtual_machine + virtual_machine_bind)
  --reset-link              Reset UI/link data in vm.db so the app can recreate it
  --target-volume /volume2  Target volume for DR
  --os-type <windows|linux> Set osType in DB (optional)
  --system-version <val>    Set systemVersion in DB (optional)
  --display-name <name>     Set display name in the UGREEN UI (default: <title> from XML)
  --no-service-restart      Skip systemctl restarts
  --vnc-guard <sec>         Stabilize link DB for <sec> seconds after restore/start
  --no-vnc-guard            Disable VNC guard
  --trace-link              Log link state during VNC guard
  --guard-reset-ports       Also reset vncPort/noVncPort to 0 during the guard
  --no-xml                  Skip virsh define from backup XML (disk restore only)
  --start                   Start the VM at the end
  --no-start                Do not start the VM at the end
  --shutdown-timeout <sec>  Shutdown timeout (default: 180)
  --force-stop              Use virsh destroy if shutdown hangs
  --dry-run                 Show actions only, do not execute them
  -h|--help                 Help
USAGE
  else
    cat <<'USAGE'
Usage:
  vm_restore.sh [Optionen] <VM> <BACKUP_DIR>
  vm_restore.sh [Optionen] <BACKUP_DIR> <VM>          (Reihenfolge egal)

Beispiele:
  ./vm_restore.sh Win2022 /volume2/VMBackup/04_12_2025_15-29-47
  ./vm_restore.sh /volume2/VMBackup/04_12_2025_15-29-47 Win2022
  ./vm_restore.sh 128cea77-77a0-4cb9-b4e0-1434d0feb2a6 /volume2/VMBackup/04_12_2025_15-29-47

Disaster Recovery (wenn die VM in der VM-App/Libvirt NICHT mehr existiert):
  ./vm_restore.sh --dr Win2022 /volume2/VMBackup/04_12_2025_15-29-47
  ./vm_restore.sh --dr 128cea77-77a0-4cb9-b4e0-1434d0feb2a6 /volume2/VMBackup/04_12_2025_15-29-47

Optionen:
  --config <pfad>           Konfig-Datei (default: ./vm_backup.conf)
  --dr                      Disaster-Recovery: VM aus Backup-XML definieren + Disks kopieren + DB registrieren
                            Aktiviert zusätzlich automatisch: --register-db --reset-link --vnc-guard <default> --trace-link
  --register-db             Nur DB-Registrierung (virtual_machine + virtual_machine_bind) durchführen
  --reset-link              UI/Link-Infos in vm.db zurücksetzen, damit die App sie neu generieren kann
  --target-volume /volume2  Ziel-Volume für DR
  --os-type <windows|linux> osType in DB setzen (optional)
  --system-version <val>    systemVersion in DB setzen (optional)
  --display-name <name>     Display-Name in der UGREEN-UI setzen (default: <title> aus XML)
  --no-service-restart      Keine systemctl-Restarts
  --vnc-guard <sec>         Link-DB nach Restore/Start für <sec> Sekunden stabilisieren
  --no-vnc-guard            VNC-Guard deaktivieren
  --trace-link              Link-State während des VNC-Guards ins Log schreiben
  --guard-reset-ports       vncPort/noVncPort im Guard zusätzlich auf 0 setzen
  --no-xml                  Kein virsh define aus Backup-XML (nur Disk-Restore)
  --start                   VM am Ende starten
  --no-start                VM am Ende nicht starten
  --shutdown-timeout <sec>  Timeout für shutdown (default: 180)
  --force-stop              Bei hängendem shutdown virsh destroy verwenden
  --dry-run                 Nur anzeigen, nichts ausführen
  -h|--help                 Hilfe
USAGE
  fi
}

# -----------------------------
# Sprache früh aus der Config laden
# -----------------------------
CONFIG_FILE="$CONFIG_FILE_DEFAULT"
PRE_CONFIG_FILE="$CONFIG_FILE_DEFAULT"
PREV_ARG=""
for arg in "$@"; do
  if [[ "$PREV_ARG" == "--config" ]]; then
    PRE_CONFIG_FILE="$arg"
    PREV_ARG=""
    continue
  fi
  if [[ "$arg" == "--config" ]]; then
    PREV_ARG="--config"
  else
    PREV_ARG=""
  fi
done
if [[ -f "$PRE_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$PRE_CONFIG_FILE"
fi
normalize_lang

# -----------------------------
# Optionen parsen
# -----------------------------
CONFIG_FILE="$PRE_CONFIG_FILE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --dr|--disaster-recovery)
      DR_MODE=1
      REGISTER_DB=1
      RESET_LINK=1
      VNC_GUARD_SECS="${DR_DEFAULT_VNC_GUARD_SECS:-240}"
      TRACE_LINK=1
      shift
      ;;
    --register-db) REGISTER_DB=1; shift;;
    --reset-link) RESET_LINK=1; shift;;
    --target-volume) TARGET_VOLUME="$2"; shift 2;;
    --os-type) OS_TYPE_OVERRIDE="$2"; shift 2;;
    --system-version) SYSTEM_VERSION_OVERRIDE="$2"; shift 2;;
    --display-name) DISPLAY_NAME_OVERRIDE="$2"; shift 2;;
    --no-service-restart) NO_SERVICE_RESTART=1; shift;;
    --vnc-guard) VNC_GUARD_SECS="$2"; shift 2;;
    --no-vnc-guard) NO_VNC_GUARD=1; shift;;
    --trace-link) TRACE_LINK=1; shift;;
    --guard-reset-ports) VNC_GUARD_RESET_PORTS=1; shift;;
    --no-xml) RESTORE_XML=0; shift;;
    --start) FORCE_START=1; shift;;
    --no-start) NO_START=1; shift;;
    --shutdown-timeout) SHUTDOWN_TIMEOUT="$2"; shift 2;;
    --force-stop) FORCE_STOP=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*)
      die "Unbekannte Option: $1"
      ;;
    *)
      if [[ -z "$VM_ARG" ]]; then
        VM_ARG="$1"
      elif [[ -z "$BACKUP_ARG" ]]; then
        BACKUP_ARG="$1"
      else
        die "Zu viele Parameter: $1"
      fi
      shift
      ;;
  esac
done

# Restliche Positions-Args (falls -- genutzt wurde)
for a in "$@"; do
  if [[ -z "$VM_ARG" ]]; then
    VM_ARG="$a"
  elif [[ -z "$BACKUP_ARG" ]]; then
    BACKUP_ARG="$a"
  else
    die "Zu viele Parameter: $a"
  fi
done

# -----------------------------
# Konfig laden
# -----------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
normalize_lang

[[ -n "$VM_ARG" && -n "$BACKUP_ARG" ]] || { usage; exit 1; }

# Reihenfolge erkennen: wenn "VM_ARG" ein Verzeichnis ist und BACKUP_ARG nicht, tauschen
if [[ -d "$VM_ARG" && ! -d "$BACKUP_ARG" ]]; then
  tmp="$VM_ARG"; VM_ARG="$BACKUP_ARG"; BACKUP_ARG="$tmp"
fi
# Oder wenn VM_ARG wie ein Pfad aussieht und BACKUP_ARG nicht:
if [[ "$VM_ARG" == /* && -d "$VM_ARG" && "$BACKUP_ARG" != /* ]]; then
  tmp="$VM_ARG"; VM_ARG="$BACKUP_ARG"; BACKUP_ARG="$tmp"
fi

# BACKUP_ROOT default
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR}"
RESTORE_LOG_FILE="${RESTORE_LOG_FILE:-$SCRIPT_DIR/vm_restore.log}"

LOG_FILE="$RESTORE_LOG_FILE"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log "Starte vm_restore.sh"
log "VM-Argument: $VM_ARG"
log "Backup-Argument: $BACKUP_ARG"
log "Config: $CONFIG_FILE"
log "DR_MODE=$DR_MODE REGISTER_DB=$REGISTER_DB RESET_LINK=$RESET_LINK RESTORE_XML=$RESTORE_XML DRY_RUN=$DRY_RUN"
log "VNC_GUARD_SECS=$VNC_GUARD_SECS NO_VNC_GUARD=$NO_VNC_GUARD TRACE_LINK=$TRACE_LINK GUARD_RESET_PORTS=$VNC_GUARD_RESET_PORTS"

# -----------------------------
# Requirements
# -----------------------------
have_cmd virsh || die "virsh nicht gefunden."
have_cmd sqlite3 || log "WARN: sqlite3 nicht gefunden — DB-Registrierung wird ggf. fehlschlagen."
have_cmd rsync || die "rsync nicht gefunden."

# -----------------------------
# Backup-Verzeichnis auflösen
# -----------------------------
resolve_backup_dir() {
  local arg="$1"
  local d=""
  if [[ -d "$arg" ]]; then
    d="$(readlink -f "$arg")"
  elif [[ -d "$BACKUP_ROOT/$arg" ]]; then
    d="$(readlink -f "$BACKUP_ROOT/$arg")"
  else
    die "Backup-Verzeichnis nicht gefunden: $arg (oder $BACKUP_ROOT/$arg)"
  fi
  echo "$d"
}

BACKUP_DIR="$(resolve_backup_dir "$BACKUP_ARG")"
log "Backup-Dir: $BACKUP_DIR"

# -----------------------------
# VM / UUID aus Eingabe ableiten
# -----------------------------
# Wichtiger Hinweis:
# Im Backup entspricht der Ordnername NICHT zwingend der libvirt-UUID aus <uuid>,
# sondern dem libvirt-Domain-Namen / virName (bei UGREEN oft UUID-artig).
# Beispiel hier:
#   Ordner / virName / <name> = 128cea77-77a0-4cb9-b4e0-1434d0feb2a6
#   libvirt <uuid>            = 66038f96-3e18-4d74-9d06-dadf1eb7d2fd
#   UI-Titel / <title>        = Win2022
# Für das Restore muss deshalb IMMER zuerst der Backup-Ordner / virName ermittelt werden.
DOMAIN_NAME=""
DOMAIN_UUID=""

extract_xml_tag() {
  local xml="$1" tag="$2"
  sed -n "s:.*<${tag}>\(.*\)</${tag}>.*:\1:p" "$xml" | head -n1 | tr -d '\r'
}

extract_xml_name() {
  local xml="$1"
  extract_xml_tag "$xml" "name"
}

extract_xml_title() {
  local xml="$1"
  extract_xml_tag "$xml" "title"
}

extract_xml_uuid() {
  local xml="$1"
  extract_xml_tag "$xml" "uuid"
}

find_backup_vm_key() {
  local wanted="$1"
  local d="$2"
  local sub xml vir_name xml_name xml_title xml_uuid xml_file_base

  for sub in "$d"/*; do
    [[ -d "$sub" ]] || continue
    vir_name="$(basename "$sub")"

    xml="$(ls -1 "$sub"/*.xml 2>/dev/null | head -n1 || true)"
    [[ -n "$xml" ]] || continue

    xml_name="$(extract_xml_name "$xml" || true)"
    xml_title="$(extract_xml_title "$xml" || true)"
    xml_uuid="$(extract_xml_uuid "$xml" || true)"
    xml_file_base="$(basename "${xml%.xml}")"

    if [[ "$wanted" == "$vir_name" || "$wanted" == "$xml_name" || "$wanted" == "$xml_title" || "$wanted" == "$xml_uuid" || "$wanted" == "$xml_file_base" ]]; then
      printf '%s|%s|%s|%s\n' "$vir_name" "$xml_name" "$xml_title" "$xml_uuid"
      return 0
    fi
  done

  return 1
}

# 1) Zuerst immer im Backup suchen.
#    Das funktioniert auch im DR-Fall, wenn die VM in libvirt gar nicht mehr existiert.
resolved="$(find_backup_vm_key "$VM_ARG" "$BACKUP_DIR" 2>/dev/null || true)"
if [[ -n "$resolved" ]]; then
  IFS='|' read -r DOMAIN_UUID DOMAIN_NAME BACKUP_XML_TITLE_HINT BACKUP_XML_UUID_HINT <<< "$resolved"
  [[ -n "$DOMAIN_NAME" ]] || DOMAIN_NAME="$DOMAIN_UUID"
  if [[ -n "${BACKUP_XML_TITLE_HINT:-}" ]]; then
    log "VM-Auflösung aus Backup: Eingabe '$VM_ARG' -> virName '$DOMAIN_UUID' (Title: $BACKUP_XML_TITLE_HINT)"
  else
    log "VM-Auflösung aus Backup: Eingabe '$VM_ARG' -> virName '$DOMAIN_UUID'"
  fi
fi

# 2) Fallback: über virsh auflösen.
#    Wichtig: Für den Backup-Ordner brauchen wir den Domain-Namen / virName, NICHT virsh domuuid.
if [[ -z "$DOMAIN_UUID" ]] && virsh dominfo "$VM_ARG" >/dev/null 2>&1; then
  DOMAIN_NAME="$(virsh domname "$VM_ARG" 2>/dev/null || true)"
  [[ -n "$DOMAIN_NAME" ]] || DOMAIN_NAME="$VM_ARG"
  DOMAIN_UUID="$DOMAIN_NAME"
  log "VM-Auflösung aus libvirt: Eingabe '$VM_ARG' -> virName '$DOMAIN_UUID'"
fi

[[ -n "$DOMAIN_UUID" ]] || die "Konnte VM/UUID nicht bestimmen. Bitte VM-Titel, virName oder UUID angeben."

# Backup-VM-Ordner
VM_BACKUP_DIR="$BACKUP_DIR/$DOMAIN_UUID"
[[ -d "$VM_BACKUP_DIR" ]] || die "VM-Backup-Ordner nicht gefunden: $VM_BACKUP_DIR"

# Backup-XML & qcow2
BACKUP_XML="$(ls -1 "$VM_BACKUP_DIR"/*.xml 2>/dev/null | head -n1 || true)"

# Titel/DisplayName aus Backup-XML (UGREEN UI nutzt i.d.R. vm.db -> virtual_machine.displayName)
XML_TITLE=""
if [[ -n "$BACKUP_XML" && -f "$BACKUP_XML" ]]; then
  XML_TITLE="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$BACKUP_XML" | head -n1 | tr -d '\r')"
fi
[[ -n "$XML_TITLE" ]] && log "Backup-XML Title: $XML_TITLE"
[[ -n "$BACKUP_XML" ]] || die "Kein XML im Backup gefunden: $VM_BACKUP_DIR"

mapfile -t BACKUP_DISKS < <(ls -1 "$VM_BACKUP_DIR"/*.qcow2 2>/dev/null || true)
[[ "${#BACKUP_DISKS[@]}" -gt 0 ]] || die "Keine qcow2 im Backup gefunden: $VM_BACKUP_DIR"

log "Backup-XML: $BACKUP_XML"
log "Backup-Disks: ${#BACKUP_DISKS[@]}"

# -----------------------------
# VM Existenz prüfen
# -----------------------------
VM_EXISTS_IN_LIBVIRT=0
if virsh dominfo "${DOMAIN_NAME:-$DOMAIN_UUID}" >/dev/null 2>&1; then
  VM_EXISTS_IN_LIBVIRT=1
  # falls Name leer, nachziehen
  [[ -n "$DOMAIN_NAME" ]] || DOMAIN_NAME="$(virsh domname "$DOMAIN_UUID" 2>/dev/null || true)"
fi

# -----------------------------
# Funktionen: Disk-Mapping / Stop / Start
# -----------------------------
get_dom_state() {
  local out
  out="$(virsh domstate "$1" 2>/dev/null | tr -d '\r' | awk '{print tolower($0)}' || true)"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  else
    printf 'unknown\n'
  fi
}

shutdown_vm() {
  local dom="$1"
  local state

  [[ -n "${dom:-}" ]] || { log "WARN: shutdown_vm ohne DOM_REF -> skip."; return 0; }

  if ! virsh dominfo "$dom" >/dev/null 2>&1; then
    log "VM ist in Libvirt derzeit nicht vorhanden (dom=$dom) -> shutdown übersprungen."
    return 0
  fi

  state="$(get_dom_state "$dom")"
  if [[ "$state" == *"running"* ]]; then
    log "VM läuft -> shutdown: $dom"
    run "virsh shutdown '$dom' >/dev/null 2>&1 || true"
    local t=0
    while (( t < SHUTDOWN_TIMEOUT )); do
      state="$(get_dom_state "$dom")"
      if [[ "$state" != *"running"* ]]; then
        log "VM ist aus (state=$state)"
        return 0
      fi
      sleep 2
      (( t+=2 ))
    done
    log "WARN: shutdown Timeout erreicht (state=$state)"
    if [[ "$FORCE_STOP" -eq 1 ]]; then
      log "Force-Stop: virsh destroy $dom"
      run "virsh destroy '$dom' >/dev/null 2>&1 || true"
      sleep 2
      state="$(get_dom_state "$dom")"
      [[ "$state" != *"running"* ]] || die "VM hängt weiterhin (state=$state)"
    else
      die "VM läuft noch. Nutze --force-stop oder erhöhe --shutdown-timeout."
    fi
  else
    log "VM läuft nicht (state=$state)"
  fi
}

start_vm() {
  local dom="$1"
  log "Starte VM: $dom"
  run "virsh start '$dom' >/dev/null 2>&1"
}

get_current_disk_paths() {
  local dom="$1"
  # extrahiert <source file='...'>
  virsh dumpxml "$dom" 2>/dev/null | \
    awk -F"'" '/<source file=/{print $2}' | \
    grep -E '\.qcow2$' || true
}

determine_kvm_root() {
  # Liefert z.B. "/volume2/@kvm"
  # Heuristik (in dieser Reihenfolge):
  #  1) TARGET_VOLUME (wenn gesetzt)
  #  2) Volume aus BACKUP_DIR
  #  3) Volume aus BACKUP_XML (erste <source file='...'>)
  #  4) /volume1..4 (erst prüfen ob VM-UUID dort schon existiert, sonst erstes mit @kvm)
  local candidates=()
  local v p

  [[ -n "${TARGET_VOLUME:-}" ]] && candidates+=("$TARGET_VOLUME")

  if [[ "${BACKUP_DIR:-}" =~ ^(/volume[0-9]+) ]]; then
    candidates+=("${BASH_REMATCH[1]}")
  fi

  if [[ -n "${BACKUP_XML:-}" && -f "${BACKUP_XML:-}" ]]; then
    p="$(awk -F"'" '/<source file=/{print $2; exit}' "$BACKUP_XML" 2>/dev/null || true)"
    if [[ "$p" =~ ^(/volume[0-9]+) ]]; then
      candidates+=("${BASH_REMATCH[1]}")
    fi
  fi

  candidates+=("/volume1" "/volume2" "/volume3" "/volume4")

  # De-Dupe + First pass: wenn UUID-Verzeichnis schon existiert -> Jackpot
  local seen=" "
  for v in "${candidates[@]}"; do
    [[ -z "$v" ]] && continue
    [[ "$seen" == *" $v "* ]] && continue
    seen+=" $v "

    if [[ -d "$v/@kvm" ]]; then
      if [[ -n "${DOMAIN_UUID:-}" && -d "$v/@kvm/$DOMAIN_UUID" ]]; then
        echo "$v/@kvm"
        return 0
      fi
    fi
  done

  # Second pass: erstes vorhandenes @kvm (writable bevorzugt)
  for v in "${candidates[@]}"; do
    [[ -z "$v" ]] && continue
    if [[ -d "$v/@kvm" && -w "$v/@kvm" ]]; then
      echo "$v/@kvm"
      return 0
    fi
  done
  for v in "${candidates[@]}"; do
    [[ -z "$v" ]] && continue
    if [[ -d "$v/@kvm" ]]; then
      echo "$v/@kvm"
      return 0
    fi
  done

  # DR-Fallback: auf einem frischen NAS kann @kvm noch fehlen, obwohl das Volume
  # in der VM-App bereits ausgewählt wurde. Dann geben wir das erwartete Ziel
  # trotzdem zurück, damit der Aufrufer es anlegen kann.
  if [[ "${DR_MODE:-0}" -eq 1 ]]; then
    for v in "${candidates[@]}"; do
      [[ -z "$v" ]] && continue
      if [[ -d "$v" ]]; then
        echo "$v/@kvm"
        return 0
      fi
    done
  fi

  return 1
}

# -----------------------------
# DR: VM aus Backup neu definieren
# -----------------------------
dr_define_from_backup() {
  local uuid="$1"
  local xml="$2"

  log "DR: VM existiert nicht in Libvirt -> define aus Backup-XML"

  # Ziel-Volume bestimmen
  local vol="$TARGET_VOLUME"
  if [[ -z "$vol" ]]; then
    # versuche /volumeX aus erster Disk im XML zu nehmen
    local firstdisk
    firstdisk="$(awk -F"'" '/<source file=/{print $2; exit}' "$xml" 2>/dev/null || true)"
    if [[ "$firstdisk" =~ ^(/volume[0-9]+) ]]; then
      vol="${BASH_REMATCH[1]}"
    fi
  fi
  [[ -n "$vol" ]] || die "DR: Konnte target volume nicht bestimmen. Bitte --target-volume /volume2 setzen."
  [[ -d "$vol" ]] || die "DR: Target volume existiert nicht: $vol"

  local kvm_root="$vol/@kvm"
  if [[ ! -d "$kvm_root" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN: würde fehlendes KVM-Root anlegen: $kvm_root"
    else
      log "DR: KVM-Root fehlt auf Ziel-Volume -> lege an: $kvm_root"
      mkdir -p "$kvm_root" || die "DR: Konnte KVM-Root nicht anlegen: $kvm_root"
    fi
  fi

  local target_dir="$kvm_root/$uuid"
  run "mkdir -p '$target_dir'"

  # temp XML anlegen und Disk-Pfade auf target_dir umbiegen
  local tmpdir="$TMP_WORK_DIR"
  run "mkdir -p '$tmpdir'"
  local tmpxml="$tmpdir/${uuid}.restore.xml"
  run "cp -a '$xml' '$tmpxml'"

  # UUID im XML setzen (falls vorhanden)
  if grep -q "<uuid>" "$tmpxml" 2>/dev/null; then
    run "sed -i -E 's|<uuid>[^<]+</uuid>|<uuid>${uuid}</uuid>|' '$tmpxml'"
  fi

  # Disk-Pfade ersetzen (nach basename)
  local line path base newpath
  while read -r path; do
    [[ -n "$path" ]] || continue
    base="$(basename "$path")"
    newpath="$target_dir/$base"
    # replace exakt dieses path
    run "sed -i -E \"s|<source file='${path//\//\\/}'/>|<source file='${newpath//\//\\/}'/>|g\" '$tmpxml' || true"
    run "sed -i -E \"s|<source file=\\\"${path//\//\\/}\\\"/>|<source file=\\\"${newpath//\//\\/}\\\"/>|g\" '$tmpxml' || true"
  done < <(awk -F"'" '/<source file=/{print $2}' "$tmpxml" 2>/dev/null || true)

  # qcow2 kopieren
  log "DR: Kopiere qcow2 nach $target_dir"
  local f
  for f in "${BACKUP_DISKS[@]}"; do
    local dest="$target_dir/$(basename "$f")"
    log "  -> $(basename "$f")"
    run "rsync -a --sparse '$f' '$dest'"
  done

  # owner setzen (falls vorhanden)
  if getent passwd libvirt-qemu >/dev/null 2>&1; then
    run "chown -R libvirt-qemu:libvirt-qemu '$target_dir' 2>/dev/null || true"
  fi
  # define in libvirt
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: virsh define '$tmpxml'"
  else
    local out
    if ! out="$(virsh define "$tmpxml" 2>&1)"; then
      die "DR: virsh define fehlgeschlagen: $out"
    fi
  fi
  # Domain-Namen aus XML ziehen
  local nm xml_probe
  xml_probe="$tmpxml"
  if [[ "$DRY_RUN" -eq 1 || ! -f "$xml_probe" ]]; then
    xml_probe="$xml"
  fi
  nm="$(extract_xml_name "$xml_probe" || true)"
  [[ -n "$nm" ]] || nm="$DOMAIN_NAME"
  DOMAIN_NAME="$nm"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DR: DRY-RUN vorbereitet. Domain-Name laut XML: ${DOMAIN_NAME:-<unbekannt>}"
  else
    log "DR: virsh define ok. Domain-Name: ${DOMAIN_NAME:-<unbekannt>}"
  fi
}

# -----------------------------
# DB: Registrierung (virtual_machine, virtual_machine_bind)
# -----------------------------
find_vm_db() {
  local f

  # bevorzugt: volume1..4 (UGOS typisch)
  for f in /volume{1..4}/@appstore/com.ugreen.kvm/db/vm.db; do
    [[ -s "$f" ]] || continue
    # Plausibilität: erwartete Tabelle muss existieren
    sqlite3 "$f" ".tables" 2>/dev/null | grep -qw "virtual_machine" || continue
    echo "$f"
    return 0
  done

  # Fallback: falls UGOS mal andere Volume-Namen/Anzahlen hat
  for f in /volume*/@appstore/com.ugreen.kvm/db/vm.db; do
    [[ -s "$f" ]] || continue
    sqlite3 "$f" ".tables" 2>/dev/null | grep -qw "virtual_machine" || continue
    echo "$f"
    return 0
  done

  return 1
}
find_vm_db_by_storage_path() {
  local vol="$1" f cols where conds

  for f in /volume*/@appstore/com.ugreen.kvm/db/vm.db; do
    [[ -s "$f" ]] || continue

    sqlite3 "$f" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='storage' LIMIT 1;" 2>/dev/null | grep -qx 1 || continue

    cols="$(sqlite3 "$f" "PRAGMA table_info(storage);" 2>/dev/null | awk -F'|' '{print $2}' || true)"
    [[ -n "$cols" ]] || continue

    conds=()
    echo "$cols" | grep -Fxq "path"       && conds+=("path='$vol'")
    echo "$cols" | grep -Fxq "mountPath"  && conds+=("mountPath='$vol'")
    echo "$cols" | grep -Fxq "storagePath"&& conds+=("storagePath='$vol'")
    [[ "${#conds[@]}" -gt 0 ]] || continue

    where="WHERE $(IFS=' OR '; echo "${conds[*]}")"
    sqlite3 "$f" "SELECT 1 FROM storage $where LIMIT 1;" 2>/dev/null | grep -qx 1 || continue

    echo "$f"
    return 0
  done
  return 1
}


sqlite_table_exists() {
  local db="$1" t="$2"
  sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t' LIMIT 1;" 2>/dev/null | grep -q 1
}

sqlite_col_exists() {
  local db="$1" t="$2" c="$3"
  sqlite3 "$db" "PRAGMA table_info($t);" 2>/dev/null | awk -F'|' '{print $2}' | grep -Fxq "$c"
}

sqlite_col_count() {
  local db="$1" t="$2"
  sqlite3 "$db" "SELECT COUNT(1) FROM pragma_table_info('$t');" 2>/dev/null | tr -d '\r' || echo "0"
}

sqlite_insert_link_row() {
  # legt (best-effort) eine Basiszeile in virtual_machine_link an, falls sie fehlt.
  # Grund: UGREEN VNC/noVNC API liefert sonst "record not found".
  local db="$1" vm="$2"
  have_cmd sqlite3 || return 1
  sqlite_table_exists "$db" "virtual_machine_link" || return 1

  # Spalten ermitteln
  local cols
  cols="$(sqlite3 "$db" "PRAGMA table_info(virtual_machine_link);" 2>/dev/null | awk -F'|' '{print $2}' || true)"
  [[ -n "$cols" ]] || return 1

  # nur bekannte Spalten befüllen, Rest Defaults überlassen
  local col_list=() val_list=()
  while read -r c; do
    case "$c" in
      virName) col_list+=("virName"); val_list+=("'$vm'");;
      passwd) col_list+=("passwd"); val_list+=("''");;
      vncPort) col_list+=("vncPort"); val_list+=("0");;
      noVncPort) col_list+=("noVncPort"); val_list+=("0");;
      type) col_list+=("type"); val_list+=("0");;
      disableLink) col_list+=("disableLink"); val_list+=("0");;
      apiKey) col_list+=("apiKey"); val_list+=("'$vm'");;
      encryptedVersion) col_list+=("encryptedVersion"); val_list+=("0");;
    esac
  done <<< "$cols"

  # virName ist Pflicht
  if [[ "${#col_list[@]}" -eq 0 ]] || [[ ! " ${col_list[*]} " =~ " virName " ]]; then
    return 1
  fi

  log "DB: virtual_machine_link fehlt -> lege Basiszeile an."
  run "sqlite3 '$db' \"INSERT INTO virtual_machine_link($(IFS=,; echo "${col_list[*]}")) VALUES($(IFS=,; echo "${val_list[*]}")); \" 2>/dev/null || true"
}


wait_for_link_ports() {
  local db="$1" vm="$2" timeout="${3:-60}"
  have_cmd sqlite3 || return 1
  sqlite_table_exists "$db" "virtual_machine_link" || return 1

  local start now vnc nvnc dis row
  start="$(date +%s)"
  while true; do
    row="$(sqlite3 "$db" "SELECT IFNULL(vncPort,0),IFNULL(noVncPort,0),IFNULL(disableLink,0) FROM virtual_machine_link WHERE virName='$vm' LIMIT 1;" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$row" ]]; then
      vnc="${row%%|*}"
      nvnc="$(printf "%s" "$row" | awk -F'|' '{print $2}')"
      dis="$(printf "%s" "$row" | awk -F'|' '{print $3}')"
      if [[ "${dis:-0}" == "0" ]] && { [[ "${vnc:-0}" -gt 0 ]] || [[ "${nvnc:-0}" -gt 0 ]]; }; then
        log "DB: Link-Ports bereit (vncPort=$vnc, noVncPort=$nvnc)."
        return 0
      fi
    fi

    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 2
  done
}



systemctl_restart_best() {
  local unit="$1"
  have_cmd systemctl || return 0
  if have_cmd timeout; then
    run "timeout 15 systemctl restart '$unit' 2>/dev/null || true"
  else
    run "systemctl restart '$unit' 2>/dev/null || true"
  fi
}

restart_vm_services() {
  # Best-effort: UGOS Builds haben unterschiedliche Service-Namen
  have_cmd systemctl || { log "WARN: systemctl nicht vorhanden -> skip Service-Restart."; return 0; }

  if [[ "${NO_SERVICE_RESTART:-0}" -eq 1 ]]; then
    log "Service-Restart: übersprungen (--no-service-restart)."
    return 0
  fi

  log "Service-Restart: KVM/Libvirt/UGREEN VM Dienste neu starten (best effort)."

  local c
  for c in com.ugreen.kvm ugreen-kvm libvirtd libvirt-bin virtqemud virtlogd virtproxyd qemu-kvm; do
    systemctl_restart_best "$c"
    systemctl_restart_best "${c}.service"
  done

  # zusätzlich alle gefundenen passenden Units (falls vorhanden)
  local units
  if have_cmd timeout; then
    units="$(timeout 10 systemctl list-units --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'kvm|libvirt|virt|qemu' || true)"
  else
    units="$(systemctl list-units --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'kvm|libvirt|virt|qemu' || true)"
  fi
  if [[ -n "$units" ]]; then
    while read -r u; do
      [[ -n "$u" ]] || continue
      systemctl_restart_best "$u"
    done <<< "$units"
  fi
}

start_vnc_watchdog() {
  local db="$1" key="$2" dur="${3:-240}"  # 240s = 4 Minuten
  have_cmd sqlite3 || return 0
  sqlite_table_exists "$db" "virtual_machine_link" || return 0

  local f="/tmp/vnc_watchdog_${key}.sh"
  cat >"$f" <<EOF
#!/usr/bin/env bash
db='$db'
key='$key'
end=\$(( \$(date +%s) + $dur ))
while [[ \$(date +%s) -lt \$end ]]; do
  sqlite3 "\$db" "UPDATE virtual_machine_link
    SET passwd='', vncPort=0, noVncPort=0, type=0, disableLink=0
    WHERE virName='\$key'
      AND (passwd<>'' OR vncPort<>0 OR noVncPort<>0 OR type<>0 OR disableLink<>0);" 2>/dev/null || true
  sleep 2
done
EOF
  chmod +x "$f"
  nohup "$f" >/dev/null 2>&1 &
  log "DB: VNC-Watchdog läuft ${dur}s im Hintergrund (auto-neutralize)."
}

guess_os_type() {
  local name="${1:-}"
  local g="linux"
  if [[ "$name" =~ [Ww]in|[Ww]indows ]]; then g="windows"; fi
  echo "$g"
}
vnc_fix_final() {
  local db="$1" key="$2"
  have_cmd sqlite3 || return 0
  sqlite_table_exists "$db" "virtual_machine_link" || return 0

  # sicherstellen: Row existiert
  local cnt
  cnt="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine_link WHERE virName='$key';" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${cnt:-0}" == "0" ]]; then
    sqlite_insert_link_row "$db" "$key" || true
  fi

  local i row ak vp np dl ty pwl
  for i in $(seq 1 60); do
    row="$(sqlite3 "$db" "SELECT IFNULL(apiKey,''),IFNULL(vncPort,0),IFNULL(noVncPort,0),IFNULL(disableLink,0),IFNULL(type,0),IFNULL(LENGTH(passwd),0) FROM virtual_machine_link WHERE virName='$key' LIMIT 1;" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$row" ]]; then
      ak="$(echo "$row" | awk -F'|' '{print $1}')"
      vp="$(echo "$row" | awk -F'|' '{print $2}')"
      np="$(echo "$row" | awk -F'|' '{print $3}')"
      dl="$(echo "$row" | awk -F'|' '{print $4}')"
      ty="$(echo "$row" | awk -F'|' '{print $5}')"
      pwl="$(echo "$row" | awk -F'|' '{print $6}')"

      # Trigger: Worker hat wirklich "echte" Werte gesetzt
      if [[ ( -n "$ak" && "$ak" != "$key" ) || "${vp:-0}" -gt 0 || "${np:-0}" -gt 0 || "${dl:-0}" != "0" || "${ty:-0}" != "0" || "${pwl:-0}" -gt 0 ]]; then
        s3_exec "$db" "UPDATE virtual_machine_link SET passwd=\'\', vncPort=0, noVncPort=0, type=0, disableLink=0 WHERE virName=\'$key\';"
        sleep 2
        s3_exec "$db" "UPDATE virtual_machine_link SET passwd=\'\', vncPort=0, noVncPort=0, type=0, disableLink=0 WHERE virName=\'$key\';"
        return 0
      fi
    fi
    sleep 2
  done

  # Fallback
  s3_exec "$db" "UPDATE virtual_machine_link SET passwd=\'\', vncPort=0, noVncPort=0, type=0, disableLink=0 WHERE virName=\'$key\';"
}



dump_link_state() {
  # Ausgabe: rowid|passwd|vncPort|noVncPort|disableLink|type|len(apiKey)|encryptedVersion
  local db="$1" key="$2"
  have_cmd sqlite3 || return 0
  sqlite_table_exists "$db" "virtual_machine_link" || return 0
  sqlite3 "$db" "SELECT IFNULL(rowid,0),IFNULL(passwd,''),IFNULL(vncPort,0),IFNULL(noVncPort,0),IFNULL(disableLink,0),IFNULL(type,0),IFNULL(LENGTH(apiKey),0),IFNULL(encryptedVersion,0) FROM virtual_machine_link WHERE virName='$key' ORDER BY rowid DESC LIMIT 1;" 2>/dev/null | tr -d '\r\n' || true
}


vnc_guard() {
  local db="$1" key="$2" secs="${3:-180}"
  [[ "$NO_VNC_GUARD" -eq 1 ]] && return 0
  have_cmd sqlite3 || return 0
  sqlite_table_exists "$db" "virtual_machine_link" || return 0

  local start now last_state state row pw vnc nvnc dis ty aklen stable_hits
  start="$(date +%s)"
  last_state=""
  stable_hits=0

  log "VNC-Guard: aktiv für ${secs}s."
  log "VNC-Guard: Bitte jetzt in UGOS diese Schritte ausführen:"
  log "VNC-Guard: 1) VM öffnen und auf den Reiter 'Freigabe' gehen."
  log "VNC-Guard: 2) '+ Hinzufügen' bzw. 'Freigabelink erstellen' anklicken."
  log "VNC-Guard: 3) Zugriffsmethode wählen (meist 'LAN')."
  log "VNC-Guard: 4) Falls ein Link angezeigt wird: optional kopieren, dann auf 'Bestätigen' klicken."
  log "VNC-Guard: 5) Im Freigabe-Fenster unten auf 'Übernehmen' klicken."
  log "VNC-Guard: 6) Fenster schließen und danach auf der VM-Übersicht auf 'Verbinden' klicken."

  while true; do
    now="$(date +%s)"
    (( now - start >= secs )) && break

    # sicherstellen: Row existiert (falls die UI/Service sie löscht)
    local cnt
    cnt="$(s3_out "$db" "SELECT COUNT(1) FROM virtual_machine_link WHERE virName='$key';" | tr -d '
' || echo 0)"
    if [[ "${cnt:-0}" == "0" ]]; then
      log "VNC-Guard: Row fehlt -> Re-Insert (best effort)."
      sqlite_insert_link_row "$db" "$key" || true
    fi

    row="$(s3_out "$db" "SELECT IFNULL(passwd,''),IFNULL(vncPort,0),IFNULL(noVncPort,0),IFNULL(disableLink,0),IFNULL(type,0),IFNULL(LENGTH(apiKey),0),IFNULL(encryptedVersion,0) FROM virtual_machine_link WHERE virName='$key' LIMIT 1;" | tr -d '
' || true)"
    [[ -n "$row" ]] || { sleep 2; continue; }

    pw="$(printf "%s" "$row" | awk -F'|' '{print $1}')"
    vnc="$(printf "%s" "$row" | awk -F'|' '{print $2}')"
    nvnc="$(printf "%s" "$row" | awk -F'|' '{print $3}')"
    dis="$(printf "%s" "$row" | awk -F'|' '{print $4}')"
    ty="$(printf "%s" "$row" | awk -F'|' '{print $5}')"
    aklen="$(printf "%s" "$row" | awk -F'|' '{print $6}')"

    state="|$pw|$vnc|$nvnc|$dis|$ty|$aklen|"

    # Trace nur bei Änderung (sonst wird das Log riesig)
    if [[ "$TRACE_LINK" -eq 1 && "$state" != "$last_state" ]]; then
      log "VNC-Guard: state=${state}"
      last_state="$state"
    fi

    # Wir halten nur die "Blocker" neutral: disableLink/type/passwd.
    # Ports sind häufig kurzlebig und werden von UGOS gesetzt.
    local need_fix=0
    [[ -n "$pw" ]] && need_fix=1
    [[ "${dis:-0}" != "0" ]] && need_fix=1
    [[ "${ty:-0}" != "0" ]] && need_fix=1

    # optional: Ports ebenfalls neutralisieren (nur wenn explizit gewünscht)
    if [[ "${VNC_GUARD_RESET_PORTS:-0}" -eq 1 ]]; then
      [[ "${vnc:-0}" -ne 0 || "${nvnc:-0}" -ne 0 ]] && need_fix=1
    fi

    if [[ "$need_fix" -eq 1 ]]; then
      local sets=()
      sqlite_col_exists "$db" "virtual_machine_link" "passwd" && sets+=("passwd=''")
      sqlite_col_exists "$db" "virtual_machine_link" "disableLink" && sets+=("disableLink=0")
      sqlite_col_exists "$db" "virtual_machine_link" "type" && sets+=("type=0")
      if [[ "${VNC_GUARD_RESET_PORTS:-0}" -eq 1 ]]; then
        sqlite_col_exists "$db" "virtual_machine_link" "vncPort" && sets+=("vncPort=0")
        sqlite_col_exists "$db" "virtual_machine_link" "noVncPort" && sets+=("noVncPort=0")
      fi
      if [[ "${#sets[@]}" -gt 0 ]]; then
        s3_exec "$db" "UPDATE virtual_machine_link SET $(IFS=,; echo "${sets[*]}") WHERE virName='$key';"
      fi
      stable_hits=0
    else
      # Good state: apiKey vorhanden, Link aktiv, keine Blocker.
      if [[ -z "$pw" && "${dis:-0}" == "0" && "${ty:-0}" == "0" && "${aklen:-0}" -gt 0 && ( "${vnc:-0}" -gt 0 || "${nvnc:-0}" -gt 0 ) ]]; then
        stable_hits=$((stable_hits + 1))
        if [[ "${VNC_GUARD_EARLY_EXIT:-1}" -eq 1 && $stable_hits -ge "${VNC_GUARD_STABLE_HITS:-3}" ]]; then
          log "VNC-Guard: stabiler Link erkannt (hits=$stable_hits, vncPort=${vnc:-0}, noVncPort=${nvnc:-0}) -> beende Guard vorzeitig."
          break
        fi
      else
        stable_hits=0
      fi
    fi

    sleep 2
  done

  log "VNC-Guard: beendet."
}


db_register_vm() {
  have_cmd sqlite3 || { log "WARN: sqlite3 fehlt -> skip DB-Register."; return 0; }

  # Disk-Pfad: nimm erste qcow2 am Ziel (bei existierender VM aus dumpxml, sonst aus Target-Dir)
  local disk_path=""
  if [[ "$VM_EXISTS_IN_LIBVIRT" -eq 1 ]]; then
    disk_path="$(get_current_disk_paths "${DOMAIN_NAME:-$DOMAIN_UUID}" | head -n1 || true)"
  fi
  if [[ -z "$disk_path" ]]; then
  local kroot=""
  kroot="$(determine_kvm_root 2>/dev/null || true)"
  if [[ -n "$kroot" ]]; then
    disk_path="$kroot/$DOMAIN_UUID/$(basename "${BACKUP_DISKS[0]}")"
  else
    disk_path="/volume2/@kvm/$DOMAIN_UUID/$(basename "${BACKUP_DISKS[0]}")"
  fi
fi

  local vol_root=""
  if [[ "$disk_path" =~ ^(/volume[0-9]+) ]]; then
    vol_root="${BASH_REMATCH[1]}"
  fi
  [[ -n "$vol_root" ]] || vol_root="/volume2"

  # >>> JETZT erst DB passend zum Volume suchen
  local db=""
  db="$(find_vm_db_by_storage_path "$vol_root" 2>/dev/null || true)"
  [[ -n "$db" ]] || db="$(find_vm_db 2>/dev/null || true)"
  [[ -n "$db" && -f "$db" ]] || { log "WARN: vm.db nicht gefunden -> skip DB-Register."; return 0; }

  log "DB-Register: vm.db=$db"
  VM_DB="$db"

  local vol_name
  vol_name="$(basename "$vol_root")"

  # storage uuid ermitteln (best effort)
  local storage_uuid=""
  if sqlite_table_exists "$db" "storage"; then
    local conds=()
    sqlite_col_exists "$db" "storage" "path" && conds+=("path='$vol_root'")
    sqlite_col_exists "$db" "storage" "mountPath" && conds+=("mountPath='$vol_root'")
    sqlite_col_exists "$db" "storage" "storagePath" && conds+=("storagePath='$vol_root'")
    local where=""
    if [[ "${#conds[@]}" -gt 0 ]]; then
      where="WHERE $(IFS=' OR '; echo "${conds[*]}")"
    fi
    storage_uuid="$(sqlite3 "$db" "SELECT uuid FROM storage $where LIMIT 1;" 2>/dev/null | head -n1 || true)"
    [[ -n "$storage_uuid" ]] || storage_uuid="$(sqlite3 "$db" "SELECT uuid FROM storage LIMIT 1;" 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$storage_uuid" ]]; then
    log "WARN: storage.uuid konnte nicht bestimmt werden. virtual_machine_bind wird evtl. nicht funktionieren."
  else
    log "DB-Register: storageUUID=$storage_uuid (vol=$vol_root)"
  fi

  local display_name="${DISPLAY_NAME_OVERRIDE:-${XML_TITLE:-${DOMAIN_NAME:-$VM_ARG}}}"
  local os_type="${OS_TYPE_OVERRIDE:-$(guess_os_type "$display_name")}"
  local sys_ver="${SYSTEM_VERSION_OVERRIDE:-}"

  # virtual_machine upsert
  if sqlite_table_exists "$db" "virtual_machine"; then
    local exists
    exists="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine WHERE virName='$DOMAIN_UUID';" 2>/dev/null | tr -d '\r' || echo "0")"
    if [[ "$exists" != "0" ]]; then
      log "DB: virtual_machine existiert -> Update"
      # Update nur wenn Spalten existieren
      local sets=()
      sqlite_col_exists "$db" "virtual_machine" "displayName" && sets+=("displayName='$(printf "%s" "$display_name" | sed "s/'/''/g")'")
      sqlite_col_exists "$db" "virtual_machine" "osType" && sets+=("osType='$os_type'")
      sqlite_col_exists "$db" "virtual_machine" "systemVersion" && sets+=("systemVersion='$(printf "%s" "$sys_ver" | sed "s/'/''/g")'")
      if [[ "${#sets[@]}" -gt 0 ]]; then
        run "sqlite3 '$db' \"UPDATE virtual_machine SET $(IFS=,; echo "${sets[*]}") WHERE virName='$DOMAIN_UUID';\""
      fi
    else
      log "DB: virtual_machine fehlt -> Insert"
      local cols
      cols="$(sqlite_col_count "$db" "virtual_machine")"
      local now
      now="$(date +%s)"
      if [[ "$cols" == "8" ]]; then
        # position-based (wie im Community-Test)
        # (id, virName, displayName, osType, systemVersion, status, <0>, <epoch>)
        run "sqlite3 '$db' \"INSERT INTO virtual_machine VALUES (NULL,'$DOMAIN_UUID','$(printf "%s" "$display_name" | sed "s/'/''/g")','$os_type','$(printf "%s" "$sys_ver" | sed "s/'/''/g")','createSuccess',0,$now);\""
      else
        # best-effort named insert
        run "sqlite3 '$db' \"INSERT INTO virtual_machine(virName,displayName,osType,systemVersion,status) VALUES('$DOMAIN_UUID','$(printf "%s" "$display_name" | sed "s/'/''/g")','$os_type','$(printf "%s" "$sys_ver" | sed "s/'/''/g")','createSuccess');\""
      fi
    fi
  else
    log "WARN: Tabelle virtual_machine nicht gefunden."
  fi

  # virtual_machine_bind
  if [[ -n "$storage_uuid" ]] && sqlite_table_exists "$db" "virtual_machine_bind"; then
    local existsb
    existsb="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine_bind WHERE virName='$DOMAIN_UUID';" 2>/dev/null | tr -d '\r' || echo "0")"
    if [[ "$existsb" != "0" ]]; then
      log "DB: virtual_machine_bind existiert bereits."
    else
      log "DB: Lege virtual_machine_bind an."
      local bcols
      bcols="$(sqlite_col_count "$db" "virtual_machine_bind")"
      if [[ "$bcols" == "5" ]]; then
        run "sqlite3 '$db' \"INSERT INTO virtual_machine_bind VALUES(NULL,'$storage_uuid','$vol_name','$vol_root','$DOMAIN_UUID');\""
      else
        # best effort
        run "sqlite3 '$db' \"INSERT INTO virtual_machine_bind(storageUUID,storageName,storagePath,virName) VALUES('$storage_uuid','$vol_name','$vol_root','$DOMAIN_UUID');\""
      fi
    fi
  fi

  # Fix B) Systemtyp / Version wieder herstellen (damit die UI sauber anzeigt)
  if [[ "$RESET_LINK" -eq 1 ]] && sqlite_table_exists "$db" "virtual_machine"; then
    local norm_os="${OS_TYPE_OVERRIDE:-windows}"
    local norm_sys="${SYSTEM_VERSION_OVERRIDE:-}"
    local sets_vm=()
    sqlite_col_exists "$db" "virtual_machine" "osType" && sets_vm+=("osType='$norm_os'")
    sqlite_col_exists "$db" "virtual_machine" "systemVersion" && sets_vm+=("systemVersion='$(printf "%s" "$norm_sys" | sed "s/'/''/g")'")
    if [[ "${#sets_vm[@]}" -gt 0 ]]; then
      log "DB: Normalize osType/systemVersion (reset-link)."
      run "sqlite3 '$db' \"UPDATE virtual_machine SET $(IFS=,; echo "${sets_vm[*]}") WHERE virName='$DOMAIN_UUID';\" || true"
    fi
  fi

  # Fix A) DB wieder "neutral" setzen (damit der Dienst/Die UI den Link sauber neu generieren kann)
  if [[ "$RESET_LINK" -eq 1 ]] && sqlite_table_exists "$db" "virtual_machine_link"; then
    log "DB: Neutralize virtual_machine_link (reset-link)."

    local existsl
    existsl="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine_link WHERE virName='$DOMAIN_UUID';" 2>/dev/null | tr -d '\r\n' || echo "0")"

    # Wichtig für die UGREEN-UI (VNC/noVNC): es MUSS eine Zeile in virtual_machine_link existieren,
    # sonst liefert die API beim "Konsole öffnen" oft "record not found".
    if [[ "$existsl" == "0" ]]; then
      sqlite_insert_link_row "$db" "$DOMAIN_UUID" || true
    fi

    local sets_link=()
    sqlite_col_exists "$db" "virtual_machine_link" "passwd" && sets_link+=("passwd=''")
    sqlite_col_exists "$db" "virtual_machine_link" "vncPort" && sets_link+=("vncPort=0")
    sqlite_col_exists "$db" "virtual_machine_link" "noVncPort" && sets_link+=("noVncPort=0")
    sqlite_col_exists "$db" "virtual_machine_link" "type" && sets_link+=("type=0")
    sqlite_col_exists "$db" "virtual_machine_link" "disableLink" && sets_link+=("disableLink=0")

    if [[ "${#sets_link[@]}" -gt 0 ]]; then
      run "sqlite3 '$db' \"UPDATE virtual_machine_link SET $(IFS=,; echo "${sets_link[*]}") WHERE virName='$DOMAIN_UUID';\" || true"
    fi

    # Check
    local chk_link
    chk_link="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine_link WHERE virName='$DOMAIN_UUID';" 2>/dev/null | tr -d '\r\n' || echo "0")"
  fi

  # Fix C) Services neu starten (Cache/Worker)
  if [[ "$DR_MODE" -eq 1 || "$RESET_LINK" -eq 1 ]]; then
    restart_vm_services

    # Nach dem Service-Restart kann UGOS/UGREEN Werte in virtual_machine_link wieder "kaputt" setzen.
    # Daher den Neutral-Update (dein UltraVNC-Fix) direkt nochmal anwenden.
    if [[ "$RESET_LINK" -eq 1 ]] && sqlite_table_exists "$db" "virtual_machine_link"; then
      log "DB: Re-Apply virtual_machine_link Neutral-Update (post-service-restart)."
      # Falls die Zeile (noch) fehlt: best-effort Insert versuchen
      local chk_post
      chk_post="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine_link WHERE virName='$DOMAIN_UUID';" 2>/dev/null | tr -d '\r\n' || echo "0")"
      if [[ "${chk_post:-0}" == "0" ]]; then
        sqlite_insert_link_row "$db" "$DOMAIN_UUID" || true
      fi
      s3_exec "$db" "UPDATE virtual_machine_link SET passwd='', vncPort=0, noVncPort=0, type=0, disableLink=0 WHERE virName='$DOMAIN_UUID';"
    fi
  fi

  # Hinweis: UGREEN generiert VNC/noVNC-Ports und Token oft erst beim Öffnen der Konsole in der UI.
  # Daher warten wir hier NICHT auf vncPort/noVncPort. Wichtig ist nur, dass der DB-Record existiert.
  if [[ "$RESET_LINK" -eq 1 ]] && sqlite_table_exists "$db" "virtual_machine_link"; then
    local chk2
    chk2="$(sqlite3 "$db" "SELECT COUNT(1) FROM virtual_machine_link WHERE virName='$DOMAIN_UUID';" 2>/dev/null | tr -d '\r\n' || echo "0")"
    if [[ "$chk2" != "0" ]]; then
      log "DB: virtual_machine_link vorhanden. Wenn die UI-VNC-Konsole noch nicht geht: VM-Karte öffnen -> Konsole/VNC einmal klicken (Ports/Token werden dann neu erzeugt)."
    fi
  fi
  if [[ "$RESET_LINK" -eq 1 ]] && sqlite_table_exists "$db" "virtual_machine_link"; then
  log "DB: Final VNC Fix (post-worker)."
  vnc_fix_final "$db" "$DOMAIN_UUID"
  fi
  log "DB-Register: fertig."
}

# -----------------------------
# Restore durchführen
# -----------------------------
DOM_REF="${DOMAIN_NAME:-$DOMAIN_UUID}"
RUNNING_BEFORE=0

DR_DEFINED=0
if [[ "$VM_EXISTS_IN_LIBVIRT" -eq 0 ]]; then
  if [[ "$DR_MODE" -eq 1 ]]; then
    dr_define_from_backup "$DOMAIN_UUID" "$BACKUP_XML"
    DR_DEFINED=1
    DOM_REF="${DOMAIN_NAME:-$DOMAIN_UUID}"
    VM_EXISTS_IN_LIBVIRT=1
  else
    die "VM existiert nicht in Libvirt. Nutze --dr für Disaster Recovery."
  fi
else
  # running state merken
  st="$(get_dom_state "$DOM_REF")"
  [[ "$st" == *"running"* ]] && RUNNING_BEFORE=1
fi
# Stop VM (falls vorhanden/running)
shutdown_vm "$DOM_REF"

# optional: XML restore/define
if [[ "$RESTORE_XML" -eq 1 ]]; then
  if [[ "$DR_MODE" -eq 1 ]]; then
    # In DR: rewrite XML disk paths to target @kvm (aber nicht doppelt, wenn schon definiert)
    if [[ "$DR_DEFINED" -eq 1 ]]; then
      log "DR: VM wurde bereits definiert (skip redefine)."
    else
      log "DR: Definiere VM aus Backup-XML (Pfad-Rewrite + QCOW2 nach Ziel-@kvm)"
      dr_define_from_backup "$DOMAIN_UUID" "$BACKUP_XML"
      DR_DEFINED=1
    fi
  else
    if [[ "$VM_EXISTS_IN_LIBVIRT" -eq 1 ]]; then
      log "Restore: VM existiert bereits in Libvirt -> überspringe virsh define. Für vollständiges Re-Define bitte VM löschen und --dr verwenden."
    else
      log "Restore: virsh define aus Backup-XML"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: virsh define '$BACKUP_XML'"
      else
        out="$(virsh define "$BACKUP_XML" 2>&1)" || die "Restore: virsh define fehlgeschlagen: $out"
      fi
    fi
  fi
fi

# Disk restore
log "Restore: qcow2 zurückspielen"
mapfile -t CURRENT_DISKS < <(get_current_disk_paths "$DOM_REF")
if [[ "${#CURRENT_DISKS[@]}" -eq 0 ]]; then
  # im DR-Fall: Disks liegen unter target volume
  log "WARN: Konnte Disk-Pfade via dumpxml nicht lesen. DR-Fallback: suche unter /volume*/@kvm/$DOMAIN_UUID"
  mapfile -t CURRENT_DISKS < <(ls -1 /volume*/@kvm/"$DOMAIN_UUID"/*.qcow2 2>/dev/null || true)
fi
if [[ "${#CURRENT_DISKS[@]}" -eq 0 && "$DR_MODE" -eq 1 ]]; then
  if ! KVM_ROOT="$(determine_kvm_root)"; then
    die "DR: Konnte KVM_ROOT nicht bestimmen. Erwartet: /volume1..4/@kvm existiert."
  fi	
  
  target_dir="${KVM_ROOT}/${DOMAIN_UUID}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: würde Zielverzeichnis anlegen: $target_dir"
  else
    mkdir -p "$target_dir"
  fi

  CURRENT_DISKS=()
  for bfile in "${BACKUP_DISKS[@]}"; do
    CURRENT_DISKS+=("$target_dir/$(basename "$bfile")")
  done
  log "DR: Ziel-Disks aus Backup abgeleitet: ${#CURRENT_DISKS[@]} (Target=$target_dir)"
fi
[[ "${#CURRENT_DISKS[@]}" -gt 0 ]] || die "Keine Ziel-qcow2 gefunden."

# mapping per basename
for bfile in "${BACKUP_DISKS[@]}"; do
  bbase="$(basename "$bfile")"
  target=""
  for cdisk in "${CURRENT_DISKS[@]}"; do
    if [[ "$(basename "$cdisk")" == "$bbase" ]]; then
      target="$cdisk"
      break
    fi
  done
  [[ -n "$target" ]] || {
    # falls nur 1 Disk, nimm die einzige
    if [[ "${#CURRENT_DISKS[@]}" -eq 1 ]]; then
      target="${CURRENT_DISKS[0]}"
      log "WARN: Kein Basename-Match für $bbase -> nutze einzige Disk: $target"
    else
      die "Konnte Ziel-Disk für $bbase nicht finden. XML/Backup passt nicht zur VM."
    fi
  }

  log "  -> $(basename "$bfile")  =>  $target"

  tdir="$(dirname "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: mkdir -p '$tdir'"
    log "DRY-RUN: rsync -a --sparse '$bfile' '$target'"
  else
    run "mkdir -p '$tdir'"
    run "rsync -a --sparse '$bfile' '$target'"
  fi

  # Ownership (best effort)
  if getent passwd libvirt-qemu >/dev/null 2>&1; then
    run "chown libvirt-qemu:libvirt-qemu '$target' 2>/dev/null || true"
  fi
done

log "Restore: qcow2 fertig."

# DB Registrierung optional (bei DR default)
if [[ "$REGISTER_DB" -eq 1 ]]; then
  db_register_vm
fi

# Start-Entscheidung (erst nach DB/Link-Fix)
if [[ "$NO_START" -eq 1 ]]; then
  log "VM wird NICHT gestartet (--no-start)."
else
  if [[ "$FORCE_START" -eq 1 || "$RUNNING_BEFORE" -eq 1 || "$DR_MODE" -eq 1 ]]; then
    start_vm "$DOM_REF"
  else
    log "VM bleibt aus (war vorher aus). Nutze --start zum Starten."
  fi
fi

# Optional: Nach dem Start schreibt UGOS/Worker oft erneut Werte in virtual_machine_link.
# Daher finaler Fix NACH Start (wenn vm.db bekannt ist).
if [[ "$RESET_LINK" -eq 1 && -n "${VM_DB:-}" ]]; then
  log "DB: Final VNC Fix (post-start)."
  vnc_fix_final "$VM_DB" "$DOMAIN_UUID" || true
fi


# Optional: VNC/UI Guard (sorgt dafür, dass virtual_machine_link nicht auf type=1/disableLink=1 kippt)
if [[ "$RESET_LINK" -eq 1 && "${NO_VNC_GUARD:-0}" -eq 0 ]]; then
  if [[ -n "${VM_DB:-}" && -f "${VM_DB:-}" ]]; then
    vnc_guard "$VM_DB" "$DOMAIN_UUID" "$VNC_GUARD_SECS"
  else
    log "VNC-Guard: vm.db unbekannt -> skip."
  fi
fi

log "FERTIG. Hinweis: Falls 'Verbinden' oder die Konsole nicht sofort erscheint, VM-App/Browser-Tab neu laden und den Freigabelink in der UI erneut bestätigen/übernehmen."
exit 0
