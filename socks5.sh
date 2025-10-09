#!/bin/bash
# SOCKS5 installer & manager (fixed port 1080)
# Run as root

set +e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Run this script as root (sudo).${NC}"
  exit 1
fi

# Config
PORT=1080
DATA_DIR="/etc/socks5"
DATA_FILE="$DATA_DIR/users.db"
PASSFILE="/etc/danted/sockd.passwd"
DEFAULT_EXP_DAYS=30

mkdir -p "$DATA_DIR"
touch "$DATA_FILE"
chmod 600 "$DATA_FILE"
mkdir -p "$(dirname "$PASSFILE")"
touch "$PASSFILE"
chmod 600 "$PASSFILE"

# helper: sanitize username (no | allowed)
clean_name() {
  echo "$1" | tr -d ' |'
}

# Install danted if not present (no prompt, port fixed to 1080)
if ! command -v danted >/dev/null 2>&1; then
  echo -e "${CYAN}Dante not found — installing and configuring (port ${PORT})...${NC}"
  apt update -y
  apt install -y dante-server curl
  touch /var/log/danted.log
  chown nobody:nogroup /var/log/danted.log 2>/dev/null || true

  iface=$(ip route | awk '/^default/ {print $5; exit}')
  iface=${iface:-eth0}

  cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = ${PORT}
external: ${iface}
method: username
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

  # allow port in ufw/iptables if present
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi
  if ! iptables -L INPUT -n | grep -q "dpt:${PORT}"; then
    iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1 || true
  fi

  # Try to ensure danted systemd unit allows log dir RW (best-effort)
  if [[ -f /usr/lib/systemd/system/danted.service ]]; then
    sed -i '/\[Service\]/a ReadWriteDirectories=/var/log' /usr/lib/systemd/system/danted.service 2>/dev/null || true
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart danted >/dev/null 2>&1 || true
  systemctl enable danted >/dev/null 2>&1 || true

  if systemctl is-active --quiet danted; then
    echo -e "${GREEN}Dante installed and running on port ${PORT}.${NC}"
  else
    echo -e "${YELLOW}Warning: danted installation may have issues. Check /var/log/danted.log and systemctl status danted.${NC}"
  fi
else
  echo -e "${GREEN}Dante already installed. Skipping installer, opening manager...${NC}"
fi

# FUNCTIONS: add / delete / renew / list / auto-clean
IP=$(hostname -I | awk '{print $1}')
[ -z "$IP" ] && IP="127.0.0.1"

add_user() {
  read -p "Username: " user_raw
  user=$(clean_name "$user_raw")
  if [[ -z "$user" ]]; then
    echo -e "${RED}Username cannot be empty.${NC}"; return 1
  fi

  read -s -p "Password: " pass; echo
  if [[ -z "$pass" ]]; then
    echo -e "${YELLOW}Empty password not allowed.${NC}"; return 1
  fi

  read -p "Expired (days, default ${DEFAULT_EXP_DAYS}): " days
  days=${days:-$DEFAULT_EXP_DAYS}
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then days=$DEFAULT_EXP_DAYS; fi

  exp_date=$(date -d "+${days} days" +"%Y-%m-%d")

  if id "$user" >/dev/null 2>&1; then
    echo -e "${YELLOW}User exists: updating password & expiry.${NC}"
    echo "${user}:${pass}" | chpasswd
    usermod -e "$exp_date" "$user" 2>/dev/null || true
  else
    useradd --shell /usr/sbin/nologin --create-home false "$user" 2>/dev/null || useradd --shell /usr/sbin/nologin "$user" 2>/dev/null || true
    echo "${user}:${pass}" | chpasswd
    usermod -e "$exp_date" "$user" 2>/dev/null || true
    echo -e "${GREEN}System user $user created.${NC}"
  fi

  # Update DB (remove old line then append)
  sed -i "/^${user}|/d" "$DATA_FILE" 2>/dev/null || true
  echo "${user}|${pass}|${exp_date}" >> "$DATA_FILE"
  chmod 600 "$DATA_FILE"

  # Update PASSFILE (record plain)
  sed -i "/^${user}:/d" "$PASSFILE" 2>/dev/null || true
  echo "${user}:${pass}" >> "$PASSFILE"
  chmod 600 "$PASSFILE"

  # Restart danted gracefully (no harm)
  systemctl restart danted >/dev/null 2>&1 || true

  echo
  echo -e "${GREEN}SOCKS5 Account Created:${NC}"
  echo -e "SOCKS5 : ${IP}:${PORT}:${user}:${pass}"
  echo -e "Expired : ${exp_date} (${days} days)"
  echo
}

del_user() {
  read -p "Username to delete: " user_raw
  user=$(clean_name "$user_raw")
  if ! id "$user" >/dev/null 2>&1; then
    echo -e "${RED}User not found.${NC}"; return 1
  fi
  userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
  sed -i "/^${user}|/d" "$DATA_FILE" 2>/dev/null || true
  sed -i "/^${user}:/d" "$PASSFILE" 2>/dev/null || true
  echo -e "${GREEN}User $user deleted (system + record).${NC}"
}

renew_user() {
  read -p "Username to renew: " user_raw
  user=$(clean_name "$user_raw")
  if ! id "$user" >/dev/null 2>&1; then
    echo -e "${RED}User not found.${NC}"; return 1
  fi
  read -p "Extend days (integer): " add_days
  if ! [[ "$add_days" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid days.${NC}"; return 1
  fi

  # Try get expiry from DB first
  old_exp=$(awk -F'|' -v u="$user" '$1==u {print $3; exit}' "$DATA_FILE")
  if [[ -z "$old_exp" ]]; then
    old_exp=$(chage -l "$user" 2>/dev/null | awk -F": " '/Account expires/ {print $2}')
    if [[ "$old_exp" == "never" || -z "$old_exp" ]]; then
      old_exp=$(date +"%Y-%m-%d")
    fi
  fi

  new_exp=$(date -d "$old_exp + $add_days days" +"%Y-%m-%d")
  usermod -e "$new_exp" "$user" 2>/dev/null || true

  # update DB
  pass=$(awk -F'|' -v u="$user" '$1==u {print $2; exit}' "$DATA_FILE")
  sed -i "/^${user}|/d" "$DATA_FILE" 2>/dev/null || true
  echo "${user}|${pass}|${new_exp}" >> "$DATA_FILE"
  chmod 600 "$DATA_FILE"

  echo -e "${GREEN}Renewed $user until ${new_exp}.${NC}"
}

list_users() {
  echo -e "${CYAN}List users (from ${DATA_FILE}):${NC}"
  printf "%-16s %-12s %-12s\n" "USERNAME" "EXPIRED" "PASSWORD"
  echo "----------------------------------------------"
  while IFS='|' read -r u p e; do
    printf "%-16s %-12s %-12s\n" "$u" "$e" "$p"
  done < <(cat "$DATA_FILE" 2>/dev/null | sort)
  echo "----------------------------------------------"
}

# Auto-delete expired: called by script with --auto or by cron
auto_delete_expired() {
  TODAY=$(date +%Y-%m-%d)
  tmp=$(mktemp)
  while IFS='|' read -r u p e; do
    if [[ -z "$u" ]]; then continue; fi
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

# Setup cron.daily cleaner if not exists
setup_cron() {
  cat > /etc/cron.daily/socks5-cleaner <<'EOF'
#!/bin/bash
DB="/etc/socks5/users.db"
TODAY=$(date +%Y-%m-%d)
tmp=$(mktemp)
while IFS='|' read -r u p e; do
  if [[ -z "$u" ]]; then continue; fi
  if [[ "$TODAY" > "$e" ]]; then
    userdel -r "$u" 2>/dev/null || true
    sed -i "/^${u}:/d" /etc/danted/sockd.passwd 2>/dev/null || true
  else
    echo "${u}|${p}|${e}" >> "$tmp"
  fi
done < "$DB"
mv "$tmp" "$DB"
chmod 600 "$DB"
EOF
  chmod +x /etc/cron.daily/socks5-cleaner
}

# If called with --auto -> just run cleanup and exit
if [[ "$1" == "--auto" ]]; then
  auto_delete_expired
  exit 0
fi

# Ensure cron script exists
setup_cron

# Manager menu
while true; do
  echo
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}        SOCKS5 MANAGER${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo "1) Add User"
  echo "2) Delete User"
  echo "3) Renew User"
  echo "4) List Users"
  echo "5) Exit"
  read -p "Select option: " opt
  case "$opt" in
    1) add_user ;;
    2) del_user) del_user ;;  # fallthrough if mis-typed
    2) del_user ;; 
    3) renew_user ;;
    4) list_users ;;
    5) exit 0 ;;
    *) echo "Invalid" ;;
  esac
done
