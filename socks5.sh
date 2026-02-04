#!/usr/bin/env bash
# SOCKS5 Dante installer & manager (fixed port 1080) - Debian/Ubuntu
set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Must be root
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo -e "${RED}Run this script as root (sudo).${NC}"
  exit 1
fi

# Config
PORT=1080
DATA_DIR="/etc/socks5"
DATA_FILE="$DATA_DIR/users.db"
PASSFILE="/etc/danted/sockd.passwd"
DEFAULT_EXP_DAYS=30
CRON_FILE="/etc/cron.daily/socks5-cleaner"
DANTED_CONF="/etc/danted.conf"

# Helpers
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_systemd(){ [[ -d /run/systemd/system ]] && has_cmd systemctl; }

clean_name() { echo "${1:-}" | tr -d ' |'; }

get_iface() {
  local iface
  iface="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  echo "${iface:-eth0}"
}

ensure_base_files() {
  mkdir -p "$DATA_DIR"
  touch "$DATA_FILE"
  chmod 600 "$DATA_FILE"
  mkdir -p "$(dirname "$PASSFILE")"
  touch "$PASSFILE"
  chmod 600 "$PASSFILE"
}

# ---- APT SAFE UPDATE (fix broken backports automatically) ----
disable_broken_backports() {
  # comment any bullseye-backports lines in sources
  local changed=0
  if grep -Rqs "bullseye-backports" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    sed -i 's/^[[:space:]]*deb[[:space:]].*bullseye-backports.*$/# &/g' \
      /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
    sed -i 's/^[[:space:]]*deb-src[[:space:]].*bullseye-backports.*$/# &/g' \
      /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
    changed=1
  fi
  return $changed
}

apt_update_safe() {
  # run apt-get update; if failed because broken backports/release file, auto-disable and retry
  local log
  log="$(mktemp)"
  echo -e "${CYAN}Running apt-get update...${NC}"
  set +e
  apt-get update -y 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e

  if [[ $rc -eq 0 ]]; then
    rm -f "$log" || true
    return 0
  fi

  # detect common errors
  if grep -qiE "bullseye-backports|does not have a Release file|Updating from such a repository can't be done securely|404[[:space:]]+Not Found" "$log"; then
    echo -e "${YELLOW}APT update failed due to repo issue (likely bullseye-backports). Auto-fixing...${NC}"
    disable_broken_backports || true

    echo -e "${CYAN}Retrying apt-get update...${NC}"
    set +e
    apt-get update -y 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
  fi

  rm -f "$log" || true
  return $rc
}
# -------------------------------------------------------------

restart_danted() {
  if is_systemd; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart danted >/dev/null 2>&1 || true
    systemctl enable danted >/dev/null 2>&1 || true
  else
    service danted restart >/dev/null 2>&1 || true
    update-rc.d danted defaults >/dev/null 2>&1 || true
  fi
}

status_danted() {
  if is_systemd; then
    systemctl is-active --quiet danted && return 0 || return 1
  else
    service danted status >/dev/null 2>&1 && return 0 || return 1
  fi
}

open_firewall_port() {
  # ufw (optional)
  if has_cmd ufw && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi

  # iptables (best effort)
  if has_cmd iptables; then
    if ! iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1 || true
    fi
  fi
}

setup_cron() {
  cat > "$CRON_FILE" <<'EOF'
#!/bin/bash
DB="/etc/socks5/users.db"
PASSFILE="/etc/danted/sockd.passwd"
TODAY=$(date +%Y-%m-%d)
tmp=$(mktemp)

while IFS='|' read -r u p e; do
  [[ -z "$u" ]] && continue

  # lifetime skip
  if [[ "$e" == "LIFETIME" ]]; then
    echo "${u}|${p}|${e}" >> "$tmp"
    continue
  fi

  if [[ "$TODAY" > "$e" ]]; then
    userdel -r "$u" 2>/dev/null || true
    sed -i "/^${u}:/d" "$PASSFILE" 2>/dev/null || true
  else
    echo "${u}|${p}|${e}" >> "$tmp"
  fi
done < "$DB"

mv "$tmp" "$DB"
chmod 600 "$DB"
EOF
  chmod +x "$CRON_FILE"
}

auto_delete_expired() {
  ensure_base_files
  local TODAY tmp
  TODAY=$(date +%Y-%m-%d)
  tmp=$(mktemp)

  while IFS='|' read -r u p e; do
    [[ -z "$u" ]] && continue

    if [[ "$e" == "LIFETIME" ]]; then
      echo "${u}|${p}|${e}" >> "$tmp"
      continue
    fi

    if [[ "$TODAY" > "$e" ]]; then
      echo "Removing expired user: $u (expired $e)"
      userdel -r "$u" 2>/dev/null || true
      sed -i "/^${u}:/d" "$PASSFILE" 2>/dev/null || true
    else
      echo "${u}|${p}|${e}" >> "$tmp"
    fi
  done < "$DATA_FILE"

  mv "$tmp" "$DATA_FILE"
  chmod 600 "$DATA_FILE"
}

install_socks5() {
  echo -e "${CYAN}Installing Dante SOCKS5 (port ${PORT})...${NC}"

  if [[ ! -f /etc/debian_version ]]; then
    echo -e "${YELLOW}Warning: this installer is designed for Debian/Ubuntu (APT). Proceeding anyway...${NC}"
  fi

  export DEBIAN_FRONTEND=noninteractive

  if ! apt_update_safe; then
    echo -e "${RED}apt-get update failed. Please fix your APT sources manually.${NC}"
    echo -e "${YELLOW}Tip: check /etc/apt/sources.list and /etc/apt/sources.list.d/*.list${NC}"
    return 1
  fi

  apt-get install -y dante-server curl iproute2

  # log file
  touch /var/log/danted.log
  chown nobody:nogroup /var/log/danted.log 2>/dev/null || true

  local iface
  iface="$(get_iface)"

  cat > "$DANTED_CONF" <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = ${PORT}
external: ${iface}

socksmethod: username
clientmethod: none

user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0/0 to: 0/0
  log: connect disconnect error
}

socks pass {
  from: 0/0 to: 0/0
  log: connect disconnect error
}
EOF

  ensure_base_files
  open_firewall_port
  setup_cron
  restart_danted

  if status_danted; then
    echo -e "${GREEN}Dante installed and running on port ${PORT}.${NC}"
  else
    echo -e "${YELLOW}Installed, but service not running. Check:${NC}"
    echo "  - systemctl status danted"
    echo "  - tail -n 50 /var/log/danted.log"
  fi
}

uninstall_socks5() {
  echo -e "${RED}Uninstalling SOCKS5 (Dante) + cleaning files...${NC}"

  if is_systemd; then
    systemctl stop danted >/dev/null 2>&1 || true
    systemctl disable danted >/dev/null 2>&1 || true
  else
    service danted stop >/dev/null 2>&1 || true
    update-rc.d -f danted remove >/dev/null 2>&1 || true
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get remove --purge -y dante-server >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true

  rm -f "$DANTED_CONF" >/dev/null 2>&1 || true
  rm -f "$CRON_FILE" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR" >/dev/null 2>&1 || true
  rm -f "$PASSFILE" >/dev/null 2>&1 || true
  rm -f /var/log/danted.log >/dev/null 2>&1 || true

  echo -e "${GREEN}Uninstall done.${NC}"
}

# Manager functions
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${IP:-}" ]] && IP="127.0.0.1"

add_user() {
  ensure_base_files

  read -p "Username: " user_raw
  local user pass days exp_date
  user="$(clean_name "$user_raw")"
  [[ -z "$user" ]] && { echo -e "${RED}Username cannot be empty.${NC}"; return 1; }

  read -s -p "Password: " pass; echo
  [[ -z "$pass" ]] && { echo -e "${YELLOW}Empty password not allowed.${NC}"; return 1; }

  read -p "Expired (days, 0 = lifetime, default ${DEFAULT_EXP_DAYS}): " days
  days="${days:-$DEFAULT_EXP_DAYS}"
  [[ "$days" =~ ^[0-9]+$ ]] || days="$DEFAULT_EXP_DAYS"

  if [[ "$days" -eq 0 ]]; then
    exp_date="LIFETIME"
  else
    exp_date="$(date -d "+${days} days" +"%Y-%m-%d")"
  fi

  if id "$user" >/dev/null 2>&1; then
    echo -e "${YELLOW}User exists: updating password & expiry.${NC}"
  else
    useradd --shell /usr/sbin/nologin --no-create-home "$user" 2>/dev/null \
      || useradd --shell /usr/sbin/nologin "$user" 2>/dev/null || true
    echo -e "${GREEN}System user $user created.${NC}"
  fi

  echo "${user}:${pass}" | chpasswd

  if [[ "$exp_date" == "LIFETIME" ]]; then
    usermod -e "" "$user" 2>/dev/null || true
  else
    usermod -e "$exp_date" "$user" 2>/dev/null || true
  fi

  sed -i "/^${user}|/d" "$DATA_FILE" 2>/dev/null || true
  echo "${user}|${pass}|${exp_date}" >> "$DATA_FILE"
  chmod 600 "$DATA_FILE"

  sed -i "/^${user}:/d" "$PASSFILE" 2>/dev/null || true
  echo "${user}:${pass}" >> "$PASSFILE"
  chmod 600 "$PASSFILE"

  restart_danted

  echo
  echo -e "${GREEN}SOCKS5 Account Created:${NC}"
  echo -e "SOCKS5 : ${IP}:${PORT}:${user}:${pass}"
  echo -e "Expired : ${exp_date} (${days} days)"
  echo
}

del_user() {
  ensure_base_files

  read -p "Username to delete: " user_raw
  local user
  user="$(clean_name "$user_raw")"
  if ! id "$user" >/dev/null 2>&1; then
    echo -e "${RED}User not found.${NC}"; return 1
  fi

  userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
  sed -i "/^${user}|/d" "$DATA_FILE" 2>/dev/null || true
  sed -i "/^${user}:/d" "$PASSFILE" 2>/dev/null || true
  echo -e "${GREEN}User $user deleted (system + record).${NC}"
}

renew_user() {
  ensure_base_files

  read -p "Username to renew: " user_raw
  local user add_days old_exp new_exp pass
  user="$(clean_name "$user_raw")"
  if ! id "$user" >/dev/null 2>&1; then
    echo -e "${RED}User not found.${NC}"; return 1
  fi

  read -p "Extend days (integer): " add_days
  [[ "$add_days" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid days.${NC}"; return 1; }

  old_exp="$(awk -F'|' -v u="$user" '$1==u {print $3; exit}' "$DATA_FILE" 2>/dev/null || true)"
  if [[ -z "$old_exp" || "$old_exp" == "LIFETIME" ]]; then
    old_exp="$(date +"%Y-%m-%d")"
  fi

  new_exp="$(date -d "$old_exp + $add_days days" +"%Y-%m-%d")"
  usermod -e "$new_exp" "$user" 2>/dev/null || true

  pass="$(awk -F'|' -v u="$user" '$1==u {print $2; exit}' "$DATA_FILE" 2>/dev/null || true)"
  sed -i "/^${user}|/d" "$DATA_FILE" 2>/dev/null || true
  echo "${user}|${pass}|${new_exp}" >> "$DATA_FILE"
  chmod 600 "$DATA_FILE"

  echo -e "${GREEN}Renewed $user until ${new_exp}.${NC}"
}

list_users() {
  ensure_base_files
  echo -e "${CYAN}List users (from ${DATA_FILE}):${NC}"
  printf "%-16s %-12s %-12s\n" "USERNAME" "EXPIRED" "PASSWORD"
  echo "----------------------------------------------"
  sort "$DATA_FILE" 2>/dev/null | while IFS='|' read -r u p e; do
    [[ -z "$u" ]] && continue
    printf "%-16s %-12s %-12s\n" "$u" "$e" "$p"
  done
  echo "----------------------------------------------"
}

manager_menu() {
  ensure_base_files
  setup_cron

  while true; do
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}        SOCKS5 MANAGER${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "1) Add User"
    echo "2) Delete User"
    echo "3) Renew User"
    echo "4) List Users"
    echo "5) Back"
    read -p "Select option: " opt
    case "$opt" in
      1) add_user ;;
      2) del_user ;;
      3) renew_user ;;
      4) list_users ;;
      5) return 0 ;;
      *) echo "Invalid" ;;
    esac
  done
}

main_menu() {
  while true; do
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}     SOCKS5 DANTE MENU${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "1) Install SOCKS5 (Dante)"
    echo "2) Uninstall SOCKS5 (Dante)"
    echo "3) Manage Users"
    echo "4) Run Auto-Cleanup Now"
    echo "5) Exit"
    read -p "Select option: " opt
    case "$opt" in
      1) install_socks5 ;;
      2) uninstall_socks5 ;;
      3) manager_menu ;;
      4) auto_delete_expired ;;
      5) exit 0 ;;
      *) echo "Invalid" ;;
    esac
  done
}

if [[ "${1:-}" == "--auto" ]]; then
  auto_delete_expired
  exit 0
fi

main_menu
