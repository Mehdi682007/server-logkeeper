#!/usr/bin/env bash
# Server Logkeeper — Ubuntu/Debian + systemd. No credentials or telemetry.
set -Eeuo pipefail
VERSION=1.0.0
STATE=/var/lib/server-logkeeper
CONF=/etc/server-logkeeper.conf
BIN=/usr/local/sbin/logkeeper
MAX_MB=100 KEEP=3 INTERVAL=60 JOURNAL_MB=200
FILES=(/etc/logrotate-x-ui.conf /etc/systemd/system/x-ui-logrotate.service /etc/systemd/system/x-ui-logrotate.timer /etc/logrotate.d/rsyslog /etc/systemd/system/logrotate.timer.d/90-hourly.conf /etc/systemd/journald.conf.d/90-log-retention.conf)
die() { echo "Error: $*" >&2; exit 1; }
root() { [[ $EUID == 0 ]] || die 'Run with sudo bash logkeeper.sh or sudo logkeeper.'; }
validate() {
  [[ $MAX_MB =~ ^[0-9]{1,5}$ && $KEEP =~ ^[0-9]{1,2}$ && $JOURNAL_MB =~ ^[0-9]{1,5}$ ]] || return 1
  (( MAX_MB >= 10 && MAX_MB <= 10000 && KEEP >= 1 && KEEP <= 30 && JOURNAL_MB >= 50 && JOURNAL_MB <= 10000 )) || return 1
  case $INTERVAL in 15|30|60|180|360|720|1440) ;; *) return 1;; esac
}
load() {
  if [[ -f $CONF ]]; then
    local key val
    while IFS='=' read -r key val; do
      case $key in MAX_MB|KEEP|INTERVAL|JOURNAL_MB) printf -v "$key" '%s' "$val";; esac
    done < "$CONF"
  fi
  validate || die "Invalid settings in $CONF"
}
calendar() {
  case $INTERVAL in
    15|30) echo "*-*-* *:0/$INTERVAL:00";;
    60) echo hourly;; 180) echo '*-*-* 0/3:00:00';;
    360) echo '*-*-* 0/6:00:00';; 720) echo '*-*-* 0/12:00:00';; 1440) echo daily;;
  esac
}
render_xui() {
  cat <<EOF
/var/log/x-ui/3xui.log /var/log/x-ui/3xipl-ap.log /var/log/x-ui/3xipl-ap.prev.log /var/log/x-ui/3xipl.log /var/log/x-ui/3xipl-banned.log /var/log/x-ui/3xipl-banned.prev.log {
    size ${MAX_MB}M
    rotate $KEEP
    compress
    compressoptions -1
    missingok
    notifempty
    copytruncate
    su root root
}
EOF
}
platform() {
  [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die 'Ubuntu/Debian with running systemd is required.'
  [[ -f /etc/debian_version ]] || die 'This release supports Ubuntu/Debian only.'
  local cmd
  for cmd in logrotate systemctl journalctl python3 flock; do
    command -v "$cmd" >/dev/null || die "Missing $cmd. Install prerequisites: apt-get update && apt-get install -y logrotate python3 util-linux"
  done
}
confirm() {
  local answer
  read -r -p "$1 Type YES to continue: " answer
  [[ $answer == YES ]]
}
lock() {
  exec 9>/run/lock/server-logkeeper.lock
  flock -n 9 || die 'Another Logkeeper action is running.'
}
snapshot() {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  [[ -f $STATE/snapshot.complete ]] && return
  local p
  for p in "${FILES[@]}"; do
    [[ ! -L $p ]] || die "Refusing symlink configuration: $p"
    if [[ -e $p ]]; then
      mkdir -p "$STATE/backup$(dirname "$p")"
      cp -p -- "$p" "$STATE/backup$p"
    fi
  done
  for p in x-ui-logrotate.timer logrotate.timer; do
    systemctl is-enabled "$p" > "$STATE/$p.enabled" 2>/dev/null || true
    systemctl is-active "$p" > "$STATE/$p.active" 2>/dev/null || true
  done
  touch "$STATE/snapshot.complete"
}
atomic_write() {
  local p=$1 tmp
  [[ ! -L $p ]] || die "Refusing symlink: $p"
  mkdir -p "$(dirname "$p")"
  tmp=$(mktemp "${p}.XXXXXX")
  cat > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$p"
}
restore_files() {
  local p
  for p in "${FILES[@]}"; do
    if [[ -f $STATE/backup$p ]]; then
      cp -p -- "$STATE/backup$p" "$p"
    else
      rm -f -- "$p"
    fi
  done
}
restore_timers() {
  local t
  systemctl daemon-reload
  for t in x-ui-logrotate.timer logrotate.timer; do
    if grep -qx enabled "$STATE/$t.enabled"; then systemctl enable "$t" >/dev/null; else systemctl disable "$t" >/dev/null 2>&1 || true; fi
    if grep -qx active "$STATE/$t.active"; then systemctl restart "$t"; else systemctl stop "$t" 2>/dev/null || true; fi
  done
}
configure() {
  root; platform; lock; load
  echo 'Choose retention settings (press Enter for the current value).'
  local v
  read -r -p "Log rotation threshold MB [${MAX_MB}], 10..10000: " v; MAX_MB=${v:-$MAX_MB}
  read -r -p "Compressed archives per log [${KEEP}], 1..30: " v; KEEP=${v:-$KEEP}
  read -r -p "Check interval minutes [${INTERVAL}], 15/30/60/180/360/720/1440: " v; INTERVAL=${v:-$INTERVAL}
  read -r -p "Journal budget MB [${JOURNAL_MB}], 50..10000: " v; JOURNAL_MB=${v:-$JOURNAL_MB}
  validate || die 'Invalid input. No settings were changed.'
  echo 'This manages x-ui-logrotate, the system logrotate timer, rsyslog retention and the journal budget.'
  echo 'Old logs may be removed on the next scheduled run. The panel is not restarted.'
  confirm 'Apply settings and enable automatic rotation?' || return 0
  if [[ -e $BIN && ! -f $STATE/snapshot.complete ]]; then die "An unmanaged $BIN already exists; choose another installation location."; fi
  # Refuse duplicate x-ui policies managed outside this tool.
  if grep -R -l -E '/var/log/x-ui|3xui\.log|3xipl' /etc/logrotate.d 2>/dev/null; then
    die 'An x-ui rule already exists in /etc/logrotate.d. Consolidate it before installing.'
  fi
  snapshot
  # A separate transaction snapshot rolls failed updates back to their immediate prior state.
  local txn p
  txn=$(mktemp -d "$STATE/transaction.XXXXXX")
  for p in "${FILES[@]}" "$CONF"; do
    [[ ! -L $p ]] || die "Refusing symlink: $p"
    if [[ -f $p ]]; then mkdir -p "$txn$(dirname "$p")"; cp -p -- "$p" "$txn$p"; fi
  done
  trap 'rc=$?; if (( rc != 0 )); then for p in "${FILES[@]}" "$CONF"; do if [[ -f $txn$p ]]; then cp -p -- "$txn$p" "$p"; else rm -f -- "$p"; fi; done; systemctl daemon-reload; systemctl start logrotate.timer; [[ ! -f /etc/systemd/system/x-ui-logrotate.timer ]] || systemctl start x-ui-logrotate.timer; echo "Apply failed; previous configuration restored." >&2; fi' EXIT
  # Stop schedules and wait for active jobs before editing their configuration.
  systemctl stop x-ui-logrotate.timer logrotate.timer 2>/dev/null || true
  local _attempt
  for _attempt in {1..120}; do
    if ! systemctl show x-ui-logrotate.service logrotate.service -p ActiveState --value 2>/dev/null | grep -Eq '^(active|activating)$'; then break; fi
    sleep 1
  done
  if systemctl show x-ui-logrotate.service logrotate.service -p ActiveState --value 2>/dev/null | grep -Eq '^(active|activating)$'; then
    restore_timers; die 'Rotation is still running. Try later.'
  fi
  render_xui | atomic_write /etc/logrotate-x-ui.conf
  atomic_write /etc/systemd/system/x-ui-logrotate.service <<'EOF'
[Unit]
Description=Server Logkeeper: rotate x-ui logs
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate --state /var/lib/logrotate/x-ui.status /etc/logrotate-x-ui.conf
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=30min
EOF
  atomic_write /etc/systemd/system/x-ui-logrotate.timer <<EOF
[Unit]
Description=Server Logkeeper: scheduled x-ui log checks
[Timer]
OnCalendar=$(calendar)
AccuracySec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  atomic_write /etc/systemd/system/logrotate.timer.d/90-hourly.conf <<EOF
[Timer]
OnCalendar=
OnCalendar=$(calendar)
AccuracySec=1min
Persistent=true
EOF
  atomic_write /etc/systemd/journald.conf.d/90-log-retention.conf <<EOF
[Journal]
SystemMaxUse=${JOURNAL_MB}M
SystemKeepFree=1G
SystemMaxFileSize=25M
RuntimeMaxUse=50M
EOF
  # Edit directives in place; retain the distro's paths, permissions and postrotate hook.
  if [[ -f /etc/logrotate.d/rsyslog ]]; then
    python3 - "$MAX_MB" "$KEEP" <<'PY'
import pathlib,re,sys
p=pathlib.Path('/etc/logrotate.d/rsyslog')
s=p.read_text()
if s.count('{') != 1 or s.count('}') != 1:
    raise SystemExit('Unsupported rsyslog policy layout; use the uninstall/restore option.')
s=re.sub(r'^\s*(?:maxsize|size|rotate|delaycompress|nodelaycompress)\b[^\n]*\n','',s,flags=re.M)
s=s.replace('{','{\n    maxsize '+sys.argv[1]+'M\n    rotate '+sys.argv[2]+'\n    nodelaycompress',1)
p.write_text(s)
PY
  fi
  if ! logrotate --debug /etc/logrotate.conf > "$STATE/validation-system.log" 2>&1 || ! logrotate --debug --state /var/lib/logrotate/x-ui.status /etc/logrotate-x-ui.conf > "$STATE/validation-xui.log" 2>&1; then
    die "Validation failed. See $STATE/validation-*.log"
  fi
  atomic_write "$CONF" <<EOF
MAX_MB=$MAX_MB
KEEP=$KEEP
INTERVAL=$INTERVAL
JOURNAL_MB=$JOURNAL_MB
EOF
  if [[ $(readlink -f "${BASH_SOURCE[0]}") != "$BIN" ]]; then install -m 755 -- "${BASH_SOURCE[0]}" "$BIN"; fi
  systemctl daemon-reload
  systemctl enable --now x-ui-logrotate.timer logrotate.timer
  systemctl restart x-ui-logrotate.timer logrotate.timer systemd-journald
  trap - EXIT
  rm -rf -- "$txn"
  echo "Installed. Open the menu with: sudo logkeeper"
  echo "Backups: $STATE/backup. Use 'Rotate now' for the first run."
}
status() {
  load
  echo "Server Logkeeper v$VERSION | threshold ${MAX_MB}MB | archives $KEEP | interval ${INTERVAL}min | journal ${JOURNAL_MB}MB"
  df -h /
  echo 'Actual disk allocation (not apparent sparse-file size):'
  du -sh /var/log/x-ui /var/log/journal /var/log/syslog /var/cache/apt 2>/dev/null || true
  if command -v systemctl >/dev/null; then
    systemctl list-timers x-ui-logrotate.timer logrotate.timer --no-pager || true
    systemctl show x-ui-logrotate.service logrotate.service -p Id -p Result -p ExecMainStatus -p ActiveState || true
  fi
}
rotate_now() {
  root; platform
  [[ -f $CONF ]] || die 'Install/configure first.'
  systemctl start x-ui-logrotate.service logrotate.service
  status
}
preview() {
  root; platform
  [[ -f $CONF ]] || die 'Install/configure first.'
  logrotate --debug --state /var/lib/logrotate/x-ui.status /etc/logrotate-x-ui.conf
  logrotate --debug /etc/logrotate.conf
}
clean() {
  root; platform; lock; load
  echo 'Emergency cleanup: empties ONLY the six named active/previous x-ui logs; no databases or backups.'
  echo 'Keeps a compressed 1MB tail per affected log. Existing rotation archives stay intact.'
  echo "Also cleans APT download cache and old journals, keeping about ${JOURNAL_MB}MB."
  du -sh /var/log/x-ui /var/log/journal /var/cache/apt 2>/dev/null || true
  confirm 'Old log contents cannot be recovered. Clean now?' || return 0
  if systemctl show x-ui-logrotate.service logrotate.service -p ActiveState --value 2>/dev/null | grep -Eq '^(active|activating)$'; then die 'Rotation is running. Retry after it completes.'; fi
  # Use the same state-file lock as logrotate; never follow symlinks.
  mkdir -p /var/lib/logrotate
  touch /var/lib/logrotate/x-ui.status
  (
    flock -n 8 || die 'x-ui logrotate is running.'
    python3 - <<'PY'
import os,gzip,stat
from pathlib import Path
base=Path('/var/log/x-ui')
if base.is_symlink(): raise SystemExit('Refusing symlink log directory')
for name in ('3xui.log','3xipl-ap.log','3xipl-ap.prev.log','3xipl.log','3xipl-banned.log','3xipl-banned.prev.log'):
    p=base/name
    if not p.exists(): continue
    fd=os.open(p,os.O_RDWR|os.O_NOFOLLOW)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode): raise SystemExit('Not a regular file: '+str(p))
        if st.st_size == 0: continue
        os.lseek(fd,max(0,st.st_size-1048576),os.SEEK_SET)
        tail=os.read(fd,1048576)
        out=base/(name+'.cleanup-tail.gz')
        ofd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
        with os.fdopen(ofd,'wb') as raw:
            with gzip.GzipFile(fileobj=raw,mode='wb') as z: z.write(tail)
        os.ftruncate(fd,0)
        print('Emptied:',p)
    finally: os.close(fd)
PY
  ) 8<>/var/lib/logrotate/x-ui.status
  if command -v apt-get >/dev/null; then apt-get clean; fi
  journalctl --rotate
  journalctl --vacuum-size="${JOURNAL_MB}M"
  status
}
uninstall_tool() {
  root; platform; lock
  [[ -f $STATE/snapshot.complete ]] || die 'No original snapshot found; nothing will be removed.'
  confirm 'Restore pre-install settings and remove Logkeeper? Log files will remain.' || return 0
  systemctl stop x-ui-logrotate.timer logrotate.timer
  if systemctl show x-ui-logrotate.service logrotate.service -p ActiveState --value 2>/dev/null | grep -Eq '^(active|activating)$'; then
    restore_timers; die 'Rotation is running. Retry later.'
  fi
  restore_files; restore_timers
  systemctl restart systemd-journald
  rm -f -- "$CONF" "$BIN"
  mv -- "$STATE" "${STATE}.uninstalled.$(date +%s)"
  echo 'Removed. Original settings restored; logs and backup snapshot retained.'
}
menu() {
  local choice
  while true; do
    printf '\nServer Logkeeper v%s\n1) Disk and timer status\n2) Install / change retention and schedule\n3) Preview automatic rotation (no deletion)\n4) Rotate now (keep compressed archives)\n5) Emergency cleanup (confirmation required)\n6) Show recent automatic-run results\n7) Uninstall and restore original settings\n0) Exit\n' "$VERSION"
    read -r -p 'Choose: ' choice || return 0
    case $choice in
      1) bash "${BASH_SOURCE[0]}" --status || true;; 2) bash "${BASH_SOURCE[0]}" --install || true;; 3) bash "${BASH_SOURCE[0]}" --preview || true;;
      4) bash "${BASH_SOURCE[0]}" --rotate || true;; 5) bash "${BASH_SOURCE[0]}" --clean || true;;
      6) journalctl -u x-ui-logrotate.service -u logrotate.service -n 30 --no-pager || true;;
      7) bash "${BASH_SOURCE[0]}" --uninstall || true;; 0) return;; *) echo 'Invalid option.';;
    esac
  done
}
main() {
  case ${1:---menu} in
    --menu) menu;; --install) configure;; --status) status;; --preview) preview;;
    --rotate) rotate_now;; --clean) clean;; --uninstall) uninstall_tool;;
    --version) echo "$VERSION";;
    --help) echo 'Usage: bash logkeeper.sh [--menu|--install|--status|--preview|--rotate|--clean|--uninstall|--version]';;
    *) die 'Unknown option; use --help.';;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
