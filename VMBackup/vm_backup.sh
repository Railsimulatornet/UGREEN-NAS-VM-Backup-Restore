#!/usr/bin/env bash

# vm_backup.sh - Backup der KVM/UGREEN-VMs v4.0
# Copyright (c) 2026 Roman Glos for Ugreen NAS Community
#
# - sichert ausgewählte oder alle VMs per virsh
# - stoppt laufende VMs optional und startet sie danach wieder
# - legt pro Lauf einen Zeitstempel-Ordner im Backup-Verzeichnis an
# - versendet bei Erfolg/Fehler eine Mail (SMTP oder sendmail-Fallback)
#
# Konfiguration liegt standardmäßig in: ./vm_backup.conf

SCRIPT_NAME="vm_backup.sh"
SCRIPT_VERSION="v4.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/vm_backup.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  printf '%s
' "Config file $CONFIG_FILE not found. Please create it first."
  exit 1
fi

# Konfiguration laden
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# Defaults, falls in der Config nicht gesetzt
BACKUP_ROOT="${BACKUP_ROOT:-/volume3/dockersich/VMBackup}"
LOG_FILE="${LOG_FILE:-$BACKUP_ROOT/vm_backup.log}"
STOP_VMS="${STOP_VMS:-yes}"
RESTART_VMS="${RESTART_VMS:-yes}"
MAIL_ON="${MAIL_ON:-always}"          # always | error | never
SMTP_SERVER="${SMTP_SERVER:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_TO="${SMTP_TO:-}"
SMTP_FROM="${SMTP_FROM:-}"
RETENTION_COUNT="${RETENTION_COUNT:-0}"
SENDMAIL_BIN="${SENDMAIL_BIN:-/usr/sbin/sendmail}"
VM_NAMES="${VM_NAMES:-}"
VM_DOMAINS="${VM_DOMAINS:-}"
NAS_NAME="${NAS_NAME:-UGREEN NAS}"
SCRIPT_LANG="${SCRIPT_LANG:-de}"
MAIL_FORMAT="${MAIL_FORMAT:-html}"

# Logrotation: Größe in MB und Anzahl Dateien
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-0}"
LOG_MAX_FILES="${LOG_MAX_FILES:-5}"


normalize_lang() {
  case "${SCRIPT_LANG:-de}" in
    en|EN|english|English) SCRIPT_LANG="en" ;;
    *) SCRIPT_LANG="de" ;;
  esac
  case "${MAIL_FORMAT:-html}" in
    text|TEXT|plain|PLAIN) MAIL_FORMAT="text" ;;
    *) MAIL_FORMAT="html" ;;
  esac
}

normalize_lang
mkdir -p "$BACKUP_ROOT"

# sicherstellen, dass virsh den richtigen libvirt benutzt
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# ----------------------------------------------------------------------
# Funktionen
# ----------------------------------------------------------------------

rotate_log_if_needed() {
  # Nur rotieren, wenn aktiviert und Datei existiert
  if [ "${LOG_MAX_SIZE_MB:-0}" -le 0 ] || [ ! -f "$LOG_FILE" ]; then
    return
  fi

  local size_bytes max_bytes
  size_bytes=$(wc -c < "$LOG_FILE")
  max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))

  if [ "$size_bytes" -le "$max_bytes" ]; then
    return
  fi

  # Einfache Rotation: vm_backup.log.N ... vm_backup.log.1
  local i
  i="$LOG_MAX_FILES"
  while [ "$i" -gt 1 ]; do
    local prev=$((i - 1))
    if [ -f "${LOG_FILE}.${prev}" ]; then
      mv "${LOG_FILE}.${prev}" "${LOG_FILE}.${i}"
    fi
    i=$((i - 1))
  done

  mv "$LOG_FILE" "${LOG_FILE}.1"
}

# Log-Rotation vor dem ersten Schreiben durchführen
rotate_log_if_needed

translate_backup_msg() {
  local msg="$*"
  [[ "${SCRIPT_LANG:-de}" == "en" ]] || { printf '%s' "$msg"; return; }

  case "$msg" in
    "=== VM-Backup gestartet ===") printf '=== VM backup started ==='; return ;;
    "=== VM-Backup abgeschlossen ===") printf '=== VM backup finished ==='; return ;;
    "Keine VMs ausgewählt oder gefunden – nichts zu tun.") printf 'No VMs selected or found - nothing to do.'; return ;;
    "Keine alten Backups zu löschen.") printf 'No old backups to delete.'; return ;;
    "Benachrichtigungs-Mail per Python-SMTP versendet.") printf 'Notification email sent via Python SMTP.'; return ;;
    "Benachrichtigungs-Mail per sendmail versendet.") printf 'Notification email sent via sendmail.'; return ;;
    "Benachrichtigung wird übersprungen.") printf 'Notification skipped.'; return ;;
  esac

  if [[ "$msg" == Backup-Verzeichnis:* ]]; then
    printf 'Backup directory: %s' "${msg#Backup-Verzeichnis: }"; return
  elif [[ "$msg" == Zu\ sichernde\ VMs:* ]]; then
    printf 'VMs to back up:%s' "${msg#Zu sichernde VMs:}"; return
  elif [[ "$msg" == Bereinige\ alte\ Backups* ]]; then
    printf 'Cleaning up old backups - keeping the last %s runs.' "${RETENTION_COUNT:-0}"; return
  elif [[ "$msg" == Lösche\ altes\ Backup:* ]]; then
    printf 'Deleting old backup: %s' "${msg#Lösche altes Backup: }"; return
  elif [[ "$msg" == Vor\ Backup\ laufende\ \(selektierte\)\ VMs:* ]]; then
    printf 'Running selected VMs before backup: %s' "${msg#Vor Backup laufende (selektierte) VMs: }"; return
  elif [[ "$msg" == Vor\ Backup\ laufende\ VMs\ \(alle\):* ]]; then
    printf 'Running VMs before backup (all): %s' "${msg#Vor Backup laufende VMs (alle): }"; return
  elif [[ "$msg" == Vor\ Backup\ waren\ keine\ VMs\ aktiv.* ]]; then
    printf 'No VMs were running before the backup.'; return
  elif [[ "$msg" == Keine\ der\ ausgewählten\ VMs\ war\ vor\ dem\ Backup\ aktiv.* ]]; then
    printf 'None of the selected VMs was running before the backup. Other running VMs will not be stopped.'; return
  elif [[ "$msg" == Backup\ beendet\ mit\ Status:* ]]; then
    printf 'Backup finished with status: %s' "${msg#Backup beendet mit Status: }"; return
  elif [[ "$msg" == MAIL_ON=never* ]]; then
    printf 'MAIL_ON=never -> no notification.'; return
  fi

  if [[ "$msg" =~ ^Fahre\ VM\ (.+)\ herunter\ \.\.\.$ ]]; then
    printf 'Shutting down VM %s ...' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARNUNG:\ Konnte\ ACPI-Shutdown\ für\ (.+)\ nicht\ senden\.$ ]]; then
    printf 'WARNING: Could not send ACPI shutdown to %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^VM\ (.+)\ ist\ nun\ aus\ \(Status:\ (.+)\)\.$ ]]; then
    printf 'VM %s is now powered off (state: %s).' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^VM\ (.+)\ reagiert\ nicht\ –\ erzwinge\ Ausschalten\.$ ]]; then
    printf 'VM %s is not responding - forcing power off.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ VM\ (.+)\ konnte\ nicht\ hart\ gestoppt\ werden\.$ ]]; then
    printf 'ERROR: Failed to force-stop VM %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^Starte\ VM\ (.+)\ \.\.\.$ ]]; then
    printf 'Starting VM %s ...' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ VM\ (.+)\ konnte\ nicht\ gestartet\ werden\.$ ]]; then
    printf 'ERROR: Failed to start VM %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ Verzeichnis\ (.+)\ konnte\ nicht\ erstellt\ werden\.$ ]]; then
    printf 'ERROR: Failed to create directory %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^Sichere\ VM\ (.+)\ nach\ (.+)$ ]]; then
    printf 'Backing up VM %s to %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^XML-Definition\ für\ (.+)\ gespeichert\.$ ]]; then
    printf 'Saved XML definition for %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ XML-Definition\ für\ (.+)\ konnte\ nicht\ gesichert\ werden\.$ ]]; then
    printf 'ERROR: Failed to save XML definition for %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARNUNG:\ Für\ VM\ (.+)\ wurden\ keine\ Datenträger\ gefunden\.$ ]]; then
    printf 'WARNING: No disks found for VM %s.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ Datenträger\ nicht\ gefunden:\ (.+)\ \(VM\ (.+)\)$ ]]; then
    printf 'ERROR: Disk not found: %s (VM %s)' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^Kopiere\ (.+)\ \-\>\ (.+)$ ]]; then
    printf 'Copying %s -> %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ Kopieren\ von\ (.+)\ ist\ fehlgeschlagen\.$ ]]; then
    printf 'ERROR: Copying %s failed.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARNUNG:\ (.+)\ konnte\ nicht\ gelöscht\ werden\.$ ]]; then
    printf 'WARNING: %s could not be deleted.' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARNUNG:\ Python-SMTP\ Konfiguration\ unvollständig\.\ Fehlende\ Werte:\ (.+)$ ]]; then
    printf 'WARNING: Python SMTP configuration is incomplete. Missing values: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARNUNG:\ Python-SMTP\ wird\ übersprungen,\ da\ python3\ nicht\ verfügbar\ ist\.$ ]]; then
    printf 'WARNING: Python SMTP skipped because python3 is not available.'; return
  elif [[ "$msg" =~ ^WARNUNG:\ sendmail-Fallback\ nicht\ verfügbar\ oder\ nicht\ ausführbar:\ (.+)$ ]]; then
    printf 'WARNING: sendmail fallback is unavailable or not executable: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^WARNUNG:\ sendmail-Fallback\ übersprungen\.\ Fehlende\ Werte:\ (.+)$ ]]; then
    printf 'WARNING: sendmail fallback skipped. Missing values: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ Python-SMTP\ Versand\ fehlgeschlagen:\ (.+)$ ]]; then
    printf 'ERROR: Python SMTP sending failed: %s' "${BASH_REMATCH[1]}"; return
  elif [[ "$msg" =~ ^FEHLER:\ sendmail-Versand\ fehlgeschlagen\.$ ]]; then
    printf 'ERROR: sendmail sending failed.'; return
  elif [[ "$msg" =~ ^FEHLER:\ Backup-Verzeichnis\ konnte\ nicht\ erstellt\ werden\.$ ]]; then
    printf 'ERROR: Failed to create backup directory.'; return
  fi

  printf '%s' "$msg"
}

log() {
  local msg
  msg="$(translate_backup_msg "$*")"
  echo "$(date '+%d.%m.%Y %H:%M:%S') - $msg" | tee -a "$LOG_FILE"
}

# Deutsches Datumsformat für den Ordnernamen: 04_12_2025_14-59-44
BACKUP_TIMESTAMP="$(date '+%d_%m_%Y_%H-%M-%S')"
BACKUP_DIR="$BACKUP_ROOT/$BACKUP_TIMESTAMP"

log "=== VM-Backup gestartet ==="
log "Backup-Verzeichnis: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR" || { log "FEHLER: Backup-Verzeichnis konnte nicht erstellt werden."; exit 1; }

BACKUP_OK=1

# ----------------------------------------------------------------------
# Helper-Funktionen rund um virsh / libvirt
# ----------------------------------------------------------------------

get_all_domains() {
  virsh list --all --name 2>>"$LOG_FILE" | sed '/^$/d'
}

get_vm_title() {
  local dom="$1"
  virsh dumpxml "$dom" 2>>"$LOG_FILE" | awk -F'[<>]' '/<title>/ {print $3; exit}'
}

vm_display_name() {
  local dom="$1"
  local title
  title="$(get_vm_title "$dom")"
  if [ -n "$title" ]; then
    echo "$title ($dom)"
  else
    echo "$dom"
  fi
}

get_running_vms() {
  if virsh list --state-running --name >/dev/null 2>&1; then
    virsh list --state-running --name | sed '/^$/d'
  else
    virsh list | awk 'NR>2 && $3=="running" {print $2}'
  fi
}

stop_vms() {
  local vm state retries
  for vm in "${RUNNING_VMS_BEFORE[@]}"; do
    log "Fahre VM $(vm_display_name "$vm") herunter ..."
    virsh shutdown "$vm" >/dev/null 2>&1 || log "WARNUNG: Konnte ACPI-Shutdown für $vm nicht senden."
  done

  for vm in "${RUNNING_VMS_BEFORE[@]}"; do
    retries=60   # 60 * 5s = 5 Minuten
    while [ $retries -gt 0 ]; do
      state="$(virsh domstate "$vm" 2>/dev/null)"
      if echo "$state" | grep -qi "shut"; then
        log "VM $(vm_display_name "$vm") ist nun aus (Status: $state)."
        break
      fi
      sleep 5
      retries=$((retries - 1))
    done
    if [ $retries -le 0 ]; then
      log "VM $(vm_display_name "$vm") reagiert nicht – erzwinge Ausschalten."
      virsh destroy "$vm" >/dev/null 2>&1 || { log "FEHLER: VM $vm konnte nicht hart gestoppt werden."; BACKUP_OK=0; }
    fi
  done
}

start_vms() {
  local vm
  for vm in "${RUNNING_VMS_BEFORE[@]}"; do
    log "Starte VM $(vm_display_name "$vm") ..."
    if ! virsh start "$vm" >/dev/null 2>&1; then
      log "FEHLER: VM $vm konnte nicht gestartet werden."
      BACKUP_OK=0
    fi
  done
}

backup_vm() {
  local vm="$1"
  local vm_safe vm_dir
  vm_safe="$(echo "$vm" | tr ' ' '_')"
  vm_dir="$BACKUP_DIR/$vm_safe"

  mkdir -p "$vm_dir" || { log "FEHLER: Verzeichnis $vm_dir konnte nicht erstellt werden."; BACKUP_OK=0; return; }

  log "Sichere VM $(vm_display_name "$vm") nach $vm_dir"

  if virsh dumpxml "$vm" > "$vm_dir/${vm_safe}.xml" 2>>"$LOG_FILE"; then
    log "XML-Definition für $vm gespeichert."
  else
    log "FEHLER: XML-Definition für $vm konnte nicht gesichert werden."
    BACKUP_OK=0
  fi

  local -a disks=()
  mapfile -t disks < <(virsh domblklist "$vm" --details 2>>"$LOG_FILE" | awk '$2=="disk" && $4 ~ /^\// {print $4}')

  if [ ${#disks[@]} -eq 0 ]; then
    log "WARNUNG: Für VM $vm wurden keine Datenträger gefunden."
  fi

  local disk base cp_opts
  for disk in "${disks[@]}"; do
    if [ ! -f "$disk" ]; then
      log "FEHLER: Datenträger nicht gefunden: $disk (VM $vm)"
      BACKUP_OK=0
      continue
    fi
    base="$(basename "$disk")"
    log "Kopiere $disk -> $vm_dir/$base"
    cp_opts="-a"
    if cp --help 2>&1 | grep -q -- '--sparse'; then
      cp_opts="$cp_opts --sparse=always"
    fi
    if ! cp $cp_opts "$disk" "$vm_dir/$base" 2>>"$LOG_FILE"; then
      log "FEHLER: Kopieren von $disk ist fehlgeschlagen."
      BACKUP_OK=0
    fi
  done
}

cleanup_old_backups() {
  if [ "${RETENTION_COUNT:-0}" -gt 0 ]; then
    log "Bereinige alte Backups – es bleiben die letzten $RETENTION_COUNT Läufe."
    local -a dirs=()
    mapfile -t dirs < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)
    if [ ${#dirs[@]} -gt "$RETENTION_COUNT" ]; then
      local i
      for (( i=RETENTION_COUNT; i<${#dirs[@]}; i++ )); do
        log "Lösche altes Backup: ${dirs[$i]}"
        rm -rf "${dirs[$i]}" || log "WARNUNG: ${dirs[$i]} konnte nicht gelöscht werden."
      done
    else
      log "Keine alten Backups zu löschen."
    fi
  fi
}

get_display_list() {
  local dom
  for dom in "${VM_ARRAY[@]}"; do
    vm_display_name "$dom"
  done
}


html_escape() {
  local s="$*"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&#39;}
  printf '%s' "$s"
}

mail_missing_fields() {
  local missing=()
  [[ -n "${SMTP_SERVER:-}" ]] || missing+=("SMTP_SERVER")
  [[ -n "${SMTP_TO:-}" ]] || missing+=("SMTP_TO")
  [[ -n "${SMTP_FROM:-}" ]] || missing+=("SMTP_FROM")
  if [[ -n "${SMTP_USER:-}" && -z "${SMTP_PASS:-}" ]]; then
    missing+=("SMTP_PASS")
  elif [[ -z "${SMTP_USER:-}" && -n "${SMTP_PASS:-}" ]]; then
    missing+=("SMTP_USER")
  fi
  local out="${missing[*]}"
  out="${out// /, }"
  printf '%s' "$out"
}

build_vm_rows_plain() {
  local idx=1 vm
  for vm in "${VM_ARRAY[@]}"; do
    printf '%s. %s\n' "$idx" "$(vm_display_name "$vm")"
    idx=$((idx + 1))
  done
}

build_vm_rows_html() {
  local idx=1 vm label
  for vm in "${VM_ARRAY[@]}"; do
    label="$(html_escape "$(vm_display_name "$vm")")"
    printf '<tr><td style="padding:10px 12px;border-bottom:1px solid #e5e7eb;color:#6b7280;">%s</td><td style="padding:10px 12px;border-bottom:1px solid #e5e7eb;color:#111827;">%s</td></tr>\n' "$idx" "$label"
    idx=$((idx + 1))
  done
}

build_mail_subject() {
  local date_part
  date_part="$(date '+%d.%m.%Y')"
  if [ "$SCRIPT_LANG" = "en" ]; then
    printf 'VM Backup %s | Host: %s | %s' "$date_part" "$NAS_NAME" "$STATUS_TEXT"
  else
    printf 'VM-Backup %s | Host: %s | %s' "$date_part" "$NAS_NAME" "$STATUS_TEXT"
  fi
}

build_mail_text_body() {
  local vm_rows footer_script_label footer_rights
  vm_rows="$(build_vm_rows_plain)"
  footer_rights="Copyright (c) 2026 Roman Glos for Ugreen NAS Community"
  if [ "$SCRIPT_LANG" = "en" ]; then
    footer_script_label="Script"
    cat <<EOF
VM backup on NAS: $NAS_NAME
Hostname: $(hostname)
Status: $STATUS_TEXT
Date: $(date '+%d.%m.%Y %H:%M:%S')

Backup directory:
$BACKUP_DIR

Log file:
$LOG_FILE

Backed up VMs:
$vm_rows
---
$footer_rights
$footer_script_label: $SCRIPT_NAME $SCRIPT_VERSION
EOF
  else
    footer_script_label="Skript"
    cat <<EOF
VM-Backup auf NAS: $NAS_NAME
Hostname: $(hostname)
Status: $STATUS_TEXT
Datum: $(date '+%d.%m.%Y %H:%M:%S')

Backup-Verzeichnis:
$BACKUP_DIR

Logdatei:
$LOG_FILE

Gesicherte VMs:
$vm_rows
---
$footer_rights
$footer_script_label: $SCRIPT_NAME $SCRIPT_VERSION
EOF
  fi
}

build_mail_html_body() {
  local title_line intro host_label date_label backup_label log_label vm_label total_label footer_script_label footer_rights
  local vm_rows total_vms badge_bg badge_fg status_line
  vm_rows="$(build_vm_rows_html)"
  total_vms="${#VM_ARRAY[@]}"
  if [ "$BACKUP_OK" -eq 1 ]; then
    badge_bg="#dcfce7"
    badge_fg="#166534"
  else
    badge_bg="#fee2e2"
    badge_fg="#991b1b"
  fi
  status_line="$(html_escape "$STATUS_TEXT")"

  footer_rights="Copyright (c) 2026 Roman Glos for Ugreen NAS Community"
  if [ "$SCRIPT_LANG" = "en" ]; then
    title_line="VM Backup $(date '+%d.%m.%Y') | Host: $(html_escape "$NAS_NAME")"
    intro="Backup summary"
    host_label="Hostname"
    date_label="Date"
    backup_label="Backup directory"
    log_label="Log file"
    vm_label="Backed up VMs"
    total_label="Total"
    footer_script_label="Script"
  else
    title_line="VM-Backup $(date '+%d.%m.%Y') | Host: $(html_escape "$NAS_NAME")"
    intro="Backup-Zusammenfassung"
    host_label="Hostname"
    date_label="Datum"
    backup_label="Backup-Verzeichnis"
    log_label="Logdatei"
    vm_label="Gesicherte VMs"
    total_label="Anzahl"
    footer_script_label="Skript"
  fi

  cat <<EOF
<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f3f4f6;font-family:Segoe UI,Arial,sans-serif;color:#111827;">
    <div style="max-width:980px;margin:0 auto;background:#ffffff;border:1px solid #e5e7eb;border-radius:14px;overflow:hidden;box-shadow:0 8px 24px rgba(0,0,0,0.08);">
      <div style="padding:24px 28px;background:linear-gradient(135deg,#111827,#1f2937);color:#ffffff;">
        <div style="font-size:28px;font-weight:700;line-height:1.2;">$title_line</div>
        <div style="margin-top:10px;font-size:15px;color:#d1d5db;">$intro</div>
        <div style="display:inline-block;margin-top:16px;padding:8px 12px;border-radius:999px;background:$badge_bg;color:$badge_fg;font-size:14px;font-weight:700;">$status_line</div>
      </div>
      <div style="padding:24px 28px;">
        <table role="presentation" style="width:100%;border-collapse:separate;border-spacing:0 10px;">
          <tr>
            <td style="padding:14px 16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:10px;"><div style="font-size:12px;color:#6b7280;">$host_label</div><div style="margin-top:6px;font-size:16px;font-weight:600;">$(html_escape "$(hostname)")</div></td>
            <td style="padding:14px 16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:10px;"><div style="font-size:12px;color:#6b7280;">$date_label</div><div style="margin-top:6px;font-size:16px;font-weight:600;">$(date '+%d.%m.%Y %H:%M:%S')</div></td>
            <td style="padding:14px 16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:10px;"><div style="font-size:12px;color:#6b7280;">$total_label</div><div style="margin-top:6px;font-size:16px;font-weight:600;">$total_vms</div></td>
          </tr>
        </table>

        <div style="margin-top:18px;font-size:18px;font-weight:700;">$vm_label</div>
        <table role="presentation" style="width:100%;margin-top:12px;border-collapse:collapse;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">
          <thead>
            <tr style="background:#f9fafb;">
              <th style="text-align:left;padding:12px;border-bottom:1px solid #e5e7eb;color:#6b7280;font-size:12px;">#</th>
              <th style="text-align:left;padding:12px;border-bottom:1px solid #e5e7eb;color:#6b7280;font-size:12px;">VM</th>
            </tr>
          </thead>
          <tbody>
$vm_rows          </tbody>
        </table>

        <div style="margin-top:12px;padding:16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:10px;">
          <div style="font-size:12px;color:#6b7280;">$backup_label</div>
          <div style="margin-top:6px;font-size:14px;font-family:Consolas,Menlo,monospace;word-break:break-all;">$(html_escape "$BACKUP_DIR")</div>
        </div>

        <div style="margin-top:12px;padding:16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:10px;">
          <div style="font-size:12px;color:#6b7280;">$log_label</div>
          <div style="margin-top:6px;font-size:14px;font-family:Consolas,Menlo,monospace;word-break:break-all;">$(html_escape "$LOG_FILE")</div>
        </div>
      </div>
      <div style="padding:16px 28px 22px;border-top:1px solid #e5e7eb;background:#fafafa;color:#6b7280;font-size:12px;line-height:1.6;">
        <div>$(html_escape "$footer_rights")</div>
        <div>$footer_script_label: $(html_escape "$SCRIPT_NAME $SCRIPT_VERSION")</div>
      </div>
    </div>
  </body>
</html>
EOF
}

send_mail() {
  local subject="$1"
  local body_text="$2"
  local body_html="${3:-}"
  local python_missing=""
  local py_output=""

  if [ "$MAIL_ON" = "never" ]; then
    log "MAIL_ON=never -> keine Benachrichtigung."
    return
  fi

  python_missing="$(mail_missing_fields)"

  if command -v python3 >/dev/null 2>&1; then
    if [ -z "$python_missing" ]; then
      py_output="$({
        SMTP_SERVER="$SMTP_SERVER" \
        SMTP_PORT="$SMTP_PORT" \
        SMTP_USER="$SMTP_USER" \
        SMTP_PASS="$SMTP_PASS" \
        SMTP_FROM="$SMTP_FROM" \
        SMTP_TO="$SMTP_TO" \
        MAIL_SUBJECT="$subject" \
        MAIL_TEXT_BODY="$body_text" \
        MAIL_HTML_BODY="$body_html" \
        MAIL_FORMAT="$MAIL_FORMAT" \
        python3 - <<'PYEOF'
import os, sys, ssl, smtplib
from email.message import EmailMessage

server = os.environ.get('SMTP_SERVER', '')
port = int(os.environ.get('SMTP_PORT', '25') or '25')
user = os.environ.get('SMTP_USER', '')
password = os.environ.get('SMTP_PASS', '')
mail_from = os.environ.get('SMTP_FROM', '')
mail_to = os.environ.get('SMTP_TO', '')
subject = os.environ.get('MAIL_SUBJECT', '')
body_text = os.environ.get('MAIL_TEXT_BODY', '')
body_html = os.environ.get('MAIL_HTML_BODY', '')
mail_format = os.environ.get('MAIL_FORMAT', 'html').lower()

msg = EmailMessage()
msg['From'] = mail_from
msg['To'] = mail_to
msg['Subject'] = subject
msg.set_content(body_text or '')
if mail_format == 'html' and body_html:
    msg.add_alternative(body_html, subtype='html')

try:
    if port == 465:
        context = ssl.create_default_context()
        with smtplib.SMTP_SSL(server, port, context=context, timeout=30) as s:
            if user:
                s.login(user, password)
            s.send_message(msg)
    else:
        with smtplib.SMTP(server, port, timeout=30) as s:
            s.ehlo()
            try:
                s.starttls(context=ssl.create_default_context())
                s.ehlo()
            except Exception:
                pass
            if user:
                s.login(user, password)
            s.send_message(msg)
except Exception as e:
    print(f"EMAIL_ERROR: {e}")
    sys.exit(1)
PYEOF
      } 2>&1)"
      if [ $? -eq 0 ]; then
        log "Benachrichtigungs-Mail per Python-SMTP versendet."
        return
      fi
      py_output="${py_output#EMAIL_ERROR: }"
      [ -n "$py_output" ] || py_output="unknown error"
      log "FEHLER: Python-SMTP Versand fehlgeschlagen: $py_output"
    else
      log "WARNUNG: Python-SMTP Konfiguration unvollständig. Fehlende Werte: $python_missing"
    fi
  else
    log "WARNUNG: Python-SMTP wird übersprungen, da python3 nicht verfügbar ist."
  fi

  local sendmail_missing=()
  [[ -n "${SMTP_TO:-}" ]] || sendmail_missing+=("SMTP_TO")
  [[ -n "${SMTP_FROM:-}" ]] || sendmail_missing+=("SMTP_FROM")

  if [ ! -x "$SENDMAIL_BIN" ]; then
    log "WARNUNG: sendmail-Fallback nicht verfügbar oder nicht ausführbar: $SENDMAIL_BIN"
    log "Benachrichtigung wird übersprungen."
    return
  fi

  if [ ${#sendmail_missing[@]} -gt 0 ]; then
    log "WARNUNG: sendmail-Fallback übersprungen. Fehlende Werte: $(printf '%s' "${sendmail_missing[*]}" | sed 's/ /, /g')"
    log "Benachrichtigung wird übersprungen."
    return
  fi

  if [ "$MAIL_FORMAT" = "html" ] && [ -n "$body_html" ]; then
    {
      echo "Subject: $subject"
      echo "To: $SMTP_TO"
      echo "From: $SMTP_FROM"
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      echo "$body_html"
    } | "$SENDMAIL_BIN" -t 2>>"$LOG_FILE" || { log "FEHLER: sendmail-Versand fehlgeschlagen."; return; }
  else
    {
      echo "Subject: $subject"
      echo "To: $SMTP_TO"
      echo "From: $SMTP_FROM"
      echo
      echo "$body_text"
    } | "$SENDMAIL_BIN" -t 2>>"$LOG_FILE" || { log "FEHLER: sendmail-Versand fehlgeschlagen."; return; }
  fi

  log "Benachrichtigungs-Mail per sendmail versendet."
}

# ----------------------------------------------------------------------
# VMs bestimmen
# ----------------------------------------------------------------------

VM_ARRAY=()

if [ -n "$VM_DOMAINS" ]; then
  read -r -a VM_ARRAY <<< "$VM_DOMAINS"
else
  mapfile -t ALL_DOMAINS < <(get_all_domains)

  if [ -n "$VM_NAMES" ]; then
    read -r -a FILTER_TITLES <<< "$VM_NAMES"
    for dom in "${ALL_DOMAINS[@]}"; do
      title="$(get_vm_title "$dom")"
      for wanted in "${FILTER_TITLES[@]}"; do
        if [ "$title" = "$wanted" ]; then
          VM_ARRAY+=("$dom")
        fi
      done
    done
  else
    VM_ARRAY=("${ALL_DOMAINS[@]}")
  fi
fi

if [ ${#VM_ARRAY[@]} -eq 0 ]; then
  log "Keine VMs ausgewählt oder gefunden – nichts zu tun."
  exit 0
fi

display_list=""
for dom in "${VM_ARRAY[@]}"; do
  display_list+=" $(vm_display_name "$dom");"
done
log "Zu sichernde VMs: $display_list"

# ----------------------------------------------------------------------
# Laufende VMs merken
# ----------------------------------------------------------------------

# Neue Option: nur ausgewählte VMs stoppen oder alle?
STOP_ONLY_BACKUP_VMS="${STOP_ONLY_BACKUP_VMS:-no}"

RUNNING_VMS_BEFORE=()
if [ "$STOP_VMS" = "yes" ]; then
  mapfile -t ALL_RUNNING < <(get_running_vms)

  if [ "$STOP_ONLY_BACKUP_VMS" = "yes" ]; then
    # Schnittmenge: laufende VMs, die auch in VM_ARRAY sind
    for r in "${ALL_RUNNING[@]}"; do
      for sel in "${VM_ARRAY[@]}"; do
        if [ "$r" = "$sel" ]; then
          RUNNING_VMS_BEFORE+=("$r")
          break
        fi
      done
    done

    if [ ${#RUNNING_VMS_BEFORE[@]} -gt 0 ]; then
      log "Vor Backup laufende (selektierte) VMs: ${RUNNING_VMS_BEFORE[*]}"
    else
      log "Keine der ausgewählten VMs war vor dem Backup aktiv. Andere laufende VMs werden nicht gestoppt."
    fi
  else
    # Altes Verhalten: alle laufenden VMs stoppen
    RUNNING_VMS_BEFORE=("${ALL_RUNNING[@]}")
    if [ ${#RUNNING_VMS_BEFORE[@]} -gt 0 ]; then
      log "Vor Backup laufende VMs (alle): ${RUNNING_VMS_BEFORE[*]}"
    else
      log "Vor Backup waren keine VMs aktiv."
    fi
  fi
fi


# ----------------------------------------------------------------------
# Ablauf
# ----------------------------------------------------------------------

if [ "$STOP_VMS" = "yes" ] && [ ${#RUNNING_VMS_BEFORE[@]} -gt 0 ]; then
  stop_vms
fi

for vm in "${VM_ARRAY[@]}"; do
  backup_vm "$vm"
done

cleanup_old_backups

if [ "$RESTART_VMS" = "yes" ] && [ ${#RUNNING_VMS_BEFORE[@]} -gt 0 ]; then
  start_vms
fi

# interner Status und sprachabhängiger Text für Mail/Log
if [ "$BACKUP_OK" -eq 1 ]; then
  STATUS="SUCCESS"
  if [ "$SCRIPT_LANG" = "en" ]; then
    STATUS_TEXT="Successful"
  else
    STATUS_TEXT="Erfolgreich"
  fi
else
  STATUS="ERROR"
  if [ "$SCRIPT_LANG" = "en" ]; then
    STATUS_TEXT="Failed"
  else
    STATUS_TEXT="Fehlgeschlagen"
  fi
fi

DISPLAY_LIST="$(get_display_list)"
SUBJECT="$(build_mail_subject)"
SUMMARY_TEXT="$(build_mail_text_body)"
SUMMARY_HTML=""
if [ "$MAIL_FORMAT" = "html" ]; then
  SUMMARY_HTML="$(build_mail_html_body)"
fi

log "Backup beendet mit Status: $STATUS_TEXT"

if [ "$MAIL_ON" = "always" ] || { [ "$MAIL_ON" = "error" ] && [ "$BACKUP_OK" -ne 1 ]; }; then
  send_mail "$SUBJECT" "$SUMMARY_TEXT" "$SUMMARY_HTML"
fi

log "=== VM-Backup abgeschlossen ==="
