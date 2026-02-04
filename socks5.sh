#!/usr/bin/env bash
# SOCKS5 All-in-One Manager (Debian/Ubuntu)
# Features: Install, Uninstall, Add user, Delete user, List, Expired cleanup
# Uses Dante (danted / dante-server) + htpasswd auth

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

PORT_DEFAULT=1080
DATA_DIR="/etc/socks5"
DATA_FILE="$DATA_DIR/users.db"
PASSDIR="/etc/danted"
PASSFILE="$PASSDIR/sockd.passwd"
CONF="/etc/danted.conf"
LOGFILE="/var/log/danted.log"

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}Run as root (sudo).${NC}"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$PASSDIR"
  touch "$DATA_FILE" "$PASSFILE"
  chmod 600 "$DATA_FILE" "$PASSFILE"
}

detect_iface() {
  # Get iface from default route
  local iface
  iface="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "$iface" ]] || iface="eth0"
  echo "$iface"
}

pkg_exists() { apt-cache show "$1" >/dev/null 2>&1; }

detect_pkg_and_service() {
  # Prefer danted if present; else dante-server
  # Service names vary: danted, dante-server (sometimes sockd)
  local pkg="" svc=""

  if pkg_exists danted; then
    pkg="danted"
  elif pkg_exists dante-server; then
    pkg="dante-server"
  else
    # fallback search
    if apt-cache search -n '^danted$' | grep -q '^danted'; then pkg="danted"; fi
    if [[ -z "$pkg" ]] && apt-cache search -n '^dante-server$' | grep -q '^dante-server'; then pkg="dante-server"; fi
  fi

  if [[ -z "$pkg" ]]; then
    echo -e "${RED}Paket Dante tidak ditemukan di repo (danted / dante-server).${NC}"
    echo -e "${YELLOW}Coba: apt update && apt-cache search dante${NC}"
    return 1
  fi

  # Guess service
  if systemctl list-unit-files 2>/dev/null | grep -q '^danted\.service'; then
    svc="danted"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^dante-server\.service'; then
    svc="dante-server"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^sockd\.service'; then
    svc="sockd"
  else
    # If not installed yet, pick common default based on pkg
    if [[ "$pkg" == "danted" ]]; then
      svc="danted"
    else
      svc="dante-server"
    fi
  fi

  echo "$pkg|$svc"
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y apache2-utils >/dev/null
}

write_config() {
  local port="$1"
  local iface="$2"

  cat > "$CONF" <<EOF
logoutput: $LOGFILE
internal: 0.0.0.0 port = $port
external: $iface

socksmethod: username
clientmethod: none

user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: connect disconnect error
}
EOF
}

svc_restart() {
  local svc="$1"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc" >/dev/null 2>&1 || true
}

svc_stop_disable() {
  local svc="$1"
  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true
}

is_installed() {
  dpkg -s danted >/dev/null 2>&1 || dpkg -s dante-server >/dev/null 2>&1
}

install_socks5() {
  need_root
  ensure_dirs
  install_deps

  local info pkg svc port iface
  info="$(detect_pkg_and_service)" || exit 1
  pkg="${info%%|*}"
  svc="${info##*|}"

  read -r -p "Port SOCKS5 (default ${PORT_DEFAULT}): " port || true
  port="${port:-$PORT_DEFAULT}"

  iface="$(detect_iface)"

  echo -e "${CYAN}Installing Dante package: ${pkg}${NC}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "$pkg" >/dev/null

  # Re-detect service after install (more accurate)
  info="$(detect_pkg_and_service)" || true
  svc="${info##*|}"

  echo -e "${CYAN}Writing config: ${CONF} (iface=${iface}, port=${port})${NC}"
  write_config "$port" "$iface"

  touch "$LOGFILE" || true
  chmod 644 "$LOGFILE" || true

  echo -e "${CYAN}Restarting service: ${svc}${NC}"
  svc_restart "$svc"

  echo -e "${GREEN}DONE: SOCKS5 aktif di port ${port}${NC}"
  echo -e "${CYAN}Cek:${NC} ss -lntup | grep :${port} || (systemctl status ${svc} --no-pager)"
}

uninstall_socks5() {
  need_root

  local info pkg svc
  info="$(detect_pkg_and_service)" || true
  pkg="${info%%|*}"
  svc="${info##*|}"

  echo -e "${CYAN}Stopping services...${NC}"
  for s in danted dante-server sockd; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
      svc_stop_disable "$s"
    fi
  done
  pkill -f sockd >/dev/null 2>&1 || true

  echo -e "${CYAN}Removing packages...${NC}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove --purge -y danted dante-server apache2-utils >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
  apt-get autoclean -y >/dev/null 2>&1 || true

  echo -e "${CYAN}Deleting configs/data...${NC}"
  rm -f "$CONF" >/dev/null 2>&1 || true
  rm -rf "$PASSDIR" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR" >/dev/null 2>&1 || true
  rm -f "$LOGFILE" >/dev/null 2>&1 || true

  echo -e "${CYAN}Cleaning cron entries (if any)...${NC}"
  ( crontab -l 2>/dev/null || true ) \
    | grep -vE 'socks5|danted|dante-server|sockd|socks5-allinone' \
    | crontab - 2>/dev/null || true

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  echo -e "${GREEN}DONE: SOCKS5 sudah dihapus total.${NC}"
}

add_user() {
  need_root
  ensure_dirs

  if ! is_installed; then
    echo -e "${RED}Dante belum di-install. Pilih Install dulu.${NC}"
    return 0
  fi

  local user pass days exp
  read -r -p "Username: " user
  [[ -n "$user" ]] || { echo -e "${RED}Username kosong.${NC}"; return 0; }
  if echo "$user" | grep -qE '[[:space:]\|]'; then
    echo -e "${RED}Username tidak boleh mengandung spasi atau '|'.${NC}"
    return 0
  fi

  read -r -p "Password: " pass
  [[ -n "$pass" ]] || { echo -e "${RED}Password kosong.${NC}"; return 0; }

  read -r -p "Expire (hari, misal 30): " days
  [[ -n "$days" ]] || days="30"
  if ! echo "$days" | grep -qE '^[0-9]+$'; then
    echo -e "${RED}Expire harus angka (hari).${NC}"
    return 0
  fi

  exp="$(date -d "+${days} days" +%Y-%m-%d 2>/dev/null || true)"
  [[ -n "$exp" ]] || exp="$(python3 - <<PY
import datetime
print((datetime.date.today()+datetime.timedelta(days=int($days))).isoformat())
PY
)"

  # add/update htpasswd entry
  htpasswd -b "$PASSFILE" "$user" "$pass" >/dev/null

  # update users.db (replace if exists)
  grep -vE "^${user}\|" "$DATA_FILE" > "${DATA_FILE}.tmp" 2>/dev/null || true
  echo "${user}|${exp}" >> "${DATA_FILE}.tmp"
  mv "${DATA_FILE}.tmp" "$DATA_FILE"
  chmod 600 "$DATA_FILE" "$PASSFILE"

  # restart service
  local info svc
  info="$(detect_pkg_and_service)" || true
  svc="${info##*|}"
  svc_restart "$svc" || true

  echo -e "${GREEN}User dibuat!${NC}"
  echo "Username: $user"
  echo "Password: $pass"
  echo "Expire  : $exp"
}

del_user() {
  need_root
  ensure_dirs

  read -r -p "Username yang mau dihapus: " user
  [[ -n "$user" ]] || { echo -e "${RED}Username kosong.${NC}"; return 0; }

  # remove from db
  if [[ -f "$DATA_FILE" ]]; then
    grep -vE "^${user}\|" "$DATA_FILE" > "${DATA_FILE}.tmp" 2>/dev/null || true
    mv "${DATA_FILE}.tmp" "$DATA_FILE"
  fi

  # remove from htpasswd
  htpasswd -D "$PASSFILE" "$user" >/dev/null 2>&1 || true

  local info svc
  info="$(detect_pkg_and_service)" || true
  svc="${info##*|}"
  svc_restart "$svc" >/dev/null 2>&1 || true

  echo -e "${GREEN}User dihapus: ${user}${NC}"
}

list_user() {
  ensure_dirs
  echo -e "${CYAN}SOCKS5 USERS (username -> expiry)${NC}"
  if [[ ! -s "$DATA_FILE" ]]; then
    echo "- (kosong)"
    return 0
  fi
  awk -F'|' '{printf "- %s -> %s\n",$1,$2}' "$DATA_FILE"
}

check_expired() {
  need_root
  ensure_dirs

  if [[ ! -s "$DATA_FILE" ]]; then
    echo -e "${YELLOW}Tidak ada user.${NC}"
    return 0
  fi

  local today_s
  today_s="$(date +%s)"

  local changed="no"
  while IFS='|' read -r u e; do
    [[ -n "${u:-}" && -n "${e:-}" ]] || continue
    local exp_s
    exp_s="$(date -d "$e" +%s 2>/dev/null || echo 0)"
    if [[ "$exp_s" -ne 0 && "$today_s" -ge "$exp_s" ]]; then
      htpasswd -D "$PASSFILE" "$u" >/dev/null 2>&1 || true
      grep -vE "^${u}\|" "$DATA_FILE" > "${DATA_FILE}.tmp" 2>/dev/null || true
      mv "${DATA_FILE}.tmp" "$DATA_FILE"
      changed="yes"
      echo -e "Expired removed: ${RED}${u}${NC} (exp ${e})"
    fi
  done < "$DATA_FILE"

  if [[ "$changed" == "yes" ]]; then
    local info svc
    info="$(detect_pkg_and_service)" || true
    svc="${info##*|}"
    svc_restart "$svc" >/dev/null 2>&1 || true
    echo -e "${GREEN}Expired cleanup done.${NC}"
  else
    echo -e "${GREEN}Tidak ada user expired.${NC}"
  fi
}

setup_cron_expired() {
  need_root
  local path
  path="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  echo -e "${CYAN}Set auto-delete expired via cron:${NC}"
  echo "1) Tiap 1 jam"
  echo "2) Tiap 6 jam"
  echo "3) Tiap hari jam 00:05"
  echo "0) Batal"
  read -r -p "Choose: " c

  local rule=""
  case "$c" in
    1) rule="0 * * * *" ;;
    2) rule="0 */6 * * *" ;;
    3) rule="5 0 * * *" ;;
    0) return 0 ;;
    *) echo -e "${RED}Invalid.${NC}"; return 0 ;;
  esac

  # install/replace cron line
  ( crontab -l 2>/dev/null || true ) | grep -vE 'socks5-allinone\.sh.*check_expired' > /tmp/cron_socks5.$$ || true
  echo "${rule} bash ${path} check_expired >/dev/null 2>&1 # socks5-allinone expired cleanup" >> /tmp/cron_socks5.$$
  crontab /tmp/cron_socks5.$$
  rm -f /tmp/cron_socks5.$$

  echo -e "${GREEN}Cron dipasang: ${rule}${NC}"
}

status_socks5() {
  local info svc iface port
  info="$(detect_pkg_and_service)" || true
  svc="${info##*|}"
  iface="$(detect_iface)"
  port="$(grep -Eo 'port *= *[0-9]+' "$CONF" 2>/dev/null | head -n1 | awk '{print $3}' || true)"
  port="${port:-$PORT_DEFAULT}"

  echo -e "${CYAN}Status${NC}"
  echo "Service guess : $svc"
  echo "Interface     : $iface"
  echo "Config        : $CONF"
  echo "Users DB      : $DATA_FILE"
  echo "Passfile      : $PASSFILE"
  echo "Port detect   : $port"
  echo

  systemctl status "$svc" --no-pager 2>/dev/null || true
  echo
  ss -lntup 2>/dev/null | grep ":${port} " || echo "Port ${port} belum listen."
}

menu() {
  while true; do
    clear
    echo -e "${CYAN}SOCKS5 ALL-IN-ONE (Debian/Ubuntu)${NC}"
    echo "1. Install SOCKS5"
    echo "2. Uninstall SOCKS5 (hapus total)"
    echo "3. Add User"
    echo "4. Delete User"
    echo "5. List Users"
    echo "6. Check Expired (hapus yg exp)"
    echo "7. Setup Cron Auto Expired Cleanup"
    echo "8. Status"
    echo "0. Exit"
    echo
    read -r -p "Choose: " opt

    case "${opt:-}" in
      1) install_socks5 ;;
      2) uninstall_socks5 ;;
      3) add_user ;;
      4) del_user ;;
      5) list_user ;;
      6) check_expired ;;
      7) setup_cron_expired ;;
      8) status_socks5 ;;
      0) exit 0 ;;
      *) echo -e "${RED}Invalid!${NC}" ;;
    esac
    echo
    read -r -p "Press Enter..."
  done
}

# CLI mode (optional): allow direct command usage
case "${1:-}" in
  install) install_socks5 ;;
  uninstall) uninstall_socks5 ;;
  add) add_user ;;
  del) del_user ;;
  list) list_user ;;
  check_expired) check_expired ;;
  cron) setup_cron_expired ;;
  status) status_socks5 ;;
  "" ) menu ;;
  *) echo "Usage: $0 [install|uninstall|add|del|list|check_expired|cron|status]"; exit 1 ;;
esac
