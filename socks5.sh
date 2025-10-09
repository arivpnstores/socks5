#!/bin/bash
# ==========================================================
#  SOCKS5 INSTALLER & MANAGER - by ARISTORE
# ==========================================================

# ========== SETUB INSTALLER INI JANGAN DIHAPUS ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
url_encode() {
    local raw="$1"; local encoded=""
    for (( i=0; i<${#raw}; i++ )); do
        char="${raw:i:1}"
        case "$char" in [a-zA-Z0-9._~-]) encoded+="$char" ;; *) encoded+=$(printf '%%%02X' "'$char") ;; esac
    done; echo "$encoded"
}

if ! command -v danted &>/dev/null; then
    echo -e "${YELLOW}Installing Dante SOCKS5 server...${NC}"
    read -p "Enter port for SOCKS5 (default 1080): " port
    port=${port:-1080}
    sudo apt update -y && sudo apt install dante-server curl -y
    sudo touch /var/log/danted.log && sudo chown nobody:nogroup /var/log/danted.log
    iface=$(ip route | grep default | awk '{print $5}')
    cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $port
external: $iface
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
    systemctl daemon-reload
    systemctl restart danted
    systemctl enable danted
    echo -e "${GREEN}Dante SOCKS5 installed successfully on port $port${NC}"
fi
# ==========================================================


# ========== SOCKS5 MANAGER SYSTEM ==========
DATA_FILE="/etc/socks5/users.db"
mkdir -p /etc/socks5
touch "$DATA_FILE"

IP=$(hostname -I | awk '{print $1}')
PORT=$(grep -m1 "port" /etc/danted.conf | awk '{print $4}')

menu() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}        SOCKS5 MANAGER${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "1) Add User"
    echo -e "2) Delete User"
    echo -e "3) Renew User"
    echo -e "4) List Users"
    echo -e "5) Exit"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "Select option: " opt
    case $opt in
        1) add_user ;;
        2) del_user ;;
        3) renew_user ;;
        4) list_user ;;
        5) exit 0 ;;
        *) echo "Invalid option"; sleep 1; menu ;;
    esac
}

add_user() {
    read -p "Username: " user
    read -s -p "Password: " pass; echo
    read -p "Expired (days): " exp_days
    exp_days=${exp_days:-30}
    exp_date=$(date -d "+$exp_days days" +"%Y-%m-%d")
    useradd -e "$exp_date" -s /usr/sbin/nologin "$user" &>/dev/null
    echo "$user:$pass" | chpasswd
    echo "$user|$pass|$exp_date" >> "$DATA_FILE"
    systemctl restart danted
    echo -e "${GREEN}SOCKS5 : ${IP}:${PORT}:${user}:${pass}${NC}"
    echo -e "${YELLOW}Expired : ${exp_date} (${exp_days} days)${NC}"
}

del_user() {
    read -p "Username to delete: " user
    if ! id "$user" &>/dev/null; then
        echo -e "${RED}User not found${NC}"; sleep 1; menu
    fi
    userdel -r "$user" &>/dev/null
    sed -i "/^$user|/d" "$DATA_FILE"
    echo -e "${GREEN}User $user deleted${NC}"
}

renew_user() {
    read -p "Username to renew: " user
    if ! grep -q "^$user|" "$DATA_FILE"; then
        echo -e "${RED}User not found${NC}"; sleep 1; menu
    fi
    read -p "Extend days: " days
    old_exp=$(grep "^$user|" "$DATA_FILE" | cut -d '|' -f3)
    new_exp=$(date -d "$old_exp +$days days" +"%Y-%m-%d")
    chage -E "$new_exp" "$user"
    sed -i "s|^$user|.*|$|$user|$(grep "^$user|" "$DATA_FILE" | cut -d '|' -f2)|$new_exp|" "$DATA_FILE"
    echo -e "${GREEN}User $user renewed until $new_exp${NC}"
}

list_user() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}USERNAME      EXPIRED      PASSWORD${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    while IFS="|" read -r u p e; do
        printf "%-12s %-12s %-12s\n" "$u" "$e" "$p"
    done < "$DATA_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ========== AUTO CLEANER ==========
cat > /etc/cron.daily/socks5-cleaner <<'EOF'
#!/bin/bash
DB="/etc/socks5/users.db"
TODAY=$(date +%Y-%m-%d)
tmp=$(mktemp)
while IFS="|" read -r u p e; do
    if [[ "$TODAY" > "$e" ]]; then
        userdel -r "$u" &>/dev/null
    else
        echo "$u|$p|$e" >> "$tmp"
    fi
done < "$DB"
mv "$tmp" "$DB"
EOF
chmod +x /etc/cron.daily/socks5-cleaner

menu
