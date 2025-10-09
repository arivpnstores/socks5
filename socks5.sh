#!/bin/bash
# SETUB INSTALLER INI JANGAN DI HAPUS
#
# (Bagian installer Dante kamu tetap utuh di bawah ini.
#  Di akhir file ditambahkan manager untuk add/delete/renew/list/auto-expire)
#
# Author: (original) - kept as requested
# Modified: Ari Setiawan + ChatGPT (gabungan installer + manager)

# ----------------------------
# BEGIN ORIGINAL INSTALLER
# ----------------------------

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to URL-encode username and password
url_encode() {
    local raw="$1"
    local encoded=""
    for (( i=0; i<${#raw}; i++ )); do
        char="${raw:i:1}"
        case "$char" in
            [a-zA-Z0-9._~-]) encoded+="$char" ;;
            *) encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    echo "$encoded"
}

# Check if danted is installed
if command -v danted &> /dev/null; then
    echo -e "${GREEN}Dante SOCKS5 server is already installed.${NC}"
    echo -e "${CYAN}Do you want to (1) Reconfigure, (2) Add a new user, (3) Uninstall, or (4) Exit? (Enter 1, 2, 3, or 4):${NC}"
    read choice
    if [[ "$choice" == "1" ]]; then
        echo -e "${CYAN}Reconfiguring requires a port. Please enter the port for the SOCKS5 proxy (default: 1080):${NC}"
        read port
        port=${port:-1080}
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
            exit 1
        fi
        reconfigure=true
        add_user=false
    elif [[ "$choice" == "2" ]]; then
        echo -e "${CYAN}Adding a new user...${NC}"
        reconfigure=false
        add_user=true
    elif [[ "$choice" == "3" ]]; then
        echo -e "${YELLOW}Uninstalling Dante SOCKS5 server...${NC}"
        sudo systemctl stop danted
        sudo systemctl disable danted
        sudo apt remove --purge dante-server -y
        sudo rm -f /etc/danted.conf /var/log/danted.log
        echo -e "${GREEN}Dante SOCKS5 server has been uninstalled successfully.${NC}"
        exit 0
    else
        echo -e "${YELLOW}Exiting.${NC}"
        exit 0
    fi
else
    echo -e "${YELLOW}Dante SOCKS5 server is not installed on this system.${NC}"
    echo -e "${CYAN}Note: Port 1080 is commonly used for SOCKS5 proxies. However, it may be blocked by your ISP or server provider. If this happens, choose an alternate port.${NC}"
    echo -e "${CYAN}Please enter the port for the SOCKS5 proxy (default: 1080):${NC}"
    read port
    port=${port:-1080}
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
        exit 1
    fi
    reconfigure=true
    add_user=true
fi

# Install or Reconfigure Dante
if [[ "$reconfigure" == "true" ]]; then
    sudo apt update -y
    sudo apt install dante-server curl -y
    echo -e "${GREEN}Dante SOCKS5 server installed successfully.${NC}"

    # Create the log file before starting the service
    sudo touch /var/log/danted.log
    sudo chown nobody:nogroup /var/log/danted.log

    # Automatically detect the primary network interface
    primary_interface=$(ip route | grep default | awk '{print $5}')
    if [[ -z "$primary_interface" ]]; then
        echo -e "${RED}Could not detect the primary network interface. Please check your network settings.${NC}"
        exit 1
    fi

    # Create the configuration file
    sudo bash -c "cat <<EOF > /etc/danted.conf
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $port
external: $primary_interface
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
EOF"

    # Configure firewall rules
    if sudo ufw status | grep -q "Status: active"; then
        if ! sudo ufw status | grep -q "$port/tcp"; then
            sudo ufw allow "$port/tcp"
        fi
    fi

    if ! sudo iptables -L | grep -q "tcp dpt:$port"; then
        sudo iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    fi

    # Edit the systemd service file for danted
    sudo sed -i '/\[Service\]/a ReadWriteDirectories=/var/log' /usr/lib/systemd/system/danted.service

    # Reload the systemd daemon and restart the service
    sudo systemctl daemon-reload
    sudo systemctl restart danted
    sudo systemctl enable danted

    # Check if the service is active
    if systemctl is-active --quiet danted; then
        echo -e "${GREEN}\nSocks5 server has been reconfigured and is running on port - $port${NC}"
    else
        echo -e "${RED}\nFailed to start the Socks5 server. Please check the logs for more details: /var/log/danted.log${NC}"
        exit 1
    fi
fi

# Add user
if [[ "$add_user" == "true" ]]; then
    echo -e "${CYAN}Please enter the username for the SOCKS5 proxy:${NC}"
    read username
    echo -e "${CYAN}Please enter the password for the SOCKS5 proxy:${NC}"
    read -s password
    if id "$username" &>/dev/null; then
        echo -e "${YELLOW}User @$username already exists. Updating password.${NC}"
    else
        sudo useradd --shell /usr/sbin/nologin "$username"
        echo -e "${GREEN}User @$username created successfully.${NC}"
    fi
    echo "$username:$password" | sudo chpasswd
    echo -e "${GREEN}Password updated successfully for user: $username.${NC}"
fi

# Test the SOCKS5 proxy
if [[ "$add_user" == "true" ]]; then
    echo -e "${CYAN}\nTesting the SOCKS5 proxy with curl...${NC}"
    proxy_ip=$(hostname -I | awk '{print $1}')
    encoded_username=$(url_encode "$username")
    encoded_password=$(url_encode "$password")

    curl -x socks5://"$encoded_username":"$encoded_password"@"$proxy_ip":"$port" https://ipinfo.io/

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}\nSOCKS5 proxy test successful. Proxy is working.${NC}"
    else
        echo -e "${RED}\nSOCKS5 proxy test failed. Please check your configuration.${NC}"
    fi
fi

# ----------------------------
# END ORIGINAL INSTALLER
# ----------------------------

# ----------------------------
# BEGIN ADDED MANAGER (ADD/DEL/RENEW/LIST/AUTO-EXPIRE)
# ----------------------------

# Manager config
DATA_DIR="/etc/shock5"
PASSFILE="/etc/danted/sockd.passwd"
CRON_MARKER="# shock5-auto-delete"
DEFAULT_PORT="${port:-1080}"
[[ ! -d $DATA_DIR ]] && sudo mkdir -p $DATA_DIR && sudo chmod 700 $DATA_DIR
[[ ! -d $(dirname "$PASSFILE") ]] && sudo mkdir -p "$(dirname "$PASSFILE")"
sudo touch "$PASSFILE" 2>/dev/null || true
sudo chmod 600 "$PASSFILE" 2>/dev/null || true

# Helper url_encode is already defined above

# Add user (manager)
add_user_mgr() {
    read -p "Input Username: " username
    [[ -z $username ]] && echo -e "${RED}Username tidak boleh kosong!${NC}" && return 1

    if id "$username" &>/dev/null; then
        echo -e "${YELLOW}User $username sudah ada di sistem. Ganti password dan update expiry.${NC}"
    else
        sudo useradd --shell /usr/sbin/nologin "$username"
        echo -e "${GREEN}User $username dibuat di sistem.${NC}"
    fi

    read -s -p "Input Password: " password
    echo
    read -p "Masa aktif (hari) [contoh 30]: " days
    days=${days:-30}

    # Set system password
    echo "$username:$password" | sudo chpasswd

    # Calculate expiry date and set
    exp_date=$(date -d "+$days days" +"%Y-%m-%d")
    sudo usermod -e "$exp_date" "$username"

    # Save exp info for manager
    echo "$exp_date" | sudo tee "$DATA_DIR/$username.exp" >/dev/null

    # Save plain entry to PASSFILE for record (username:password)
    # Warning: this file is plain — permissions restricted to root
    if sudo grep -q "^${username}:" "$PASSFILE" 2>/dev/null; then
        # replace line
        sudo sed -i "s|^${username}:.*|${username}:${password}|" "$PASSFILE" 2>/dev/null || true
    else
        echo "${username}:${password}" | sudo tee -a "$PASSFILE" >/dev/null
    fi
    sudo chmod 600 "$PASSFILE"

    # Output requested format
    proxy_ip=$(hostname -I | awk '{print $1}')
    port_from_conf=$(grep -oP 'internal: 0.0.0.0 port = \K[0-9]+' /etc/danted.conf 2>/dev/null || echo "$DEFAULT_PORT")

    echo -e "${GREEN}\nSOCKS5 Account Created Successfully!${NC}"
    echo "--------------------------------------------"
    echo -e " Username : ${YELLOW}$username${NC}"
    echo -e " Password : ${YELLOW}$password${NC}"
    echo -e " Expired  : ${YELLOW}$exp_date (${days} days)${NC}"
    echo "--------------------------------------------"
    echo -e "${CYAN}SOCKS5 : ${GREEN}${proxy_ip}:${port_from_conf}:${username}:${password}${NC}"
    echo "--------------------------------------------"
}

# Delete user (manager)
delete_user_mgr() {
    read -p "Input Username yang ingin dihapus: " username
    [[ -z $username ]] && echo -e "${RED}Username kosong!${NC}" && return 1

    if ! id "$username" &>/dev/null; then
        echo -e "${RED}User tidak ditemukan di sistem.${NC}" && return 1
    fi

    sudo userdel "$username" 2>/dev/null || true
    sudo rm -f "$DATA_DIR/$username.exp"
    # Remove from passfile
    sudo sed -i "/^${username}:/d" "$PASSFILE" 2>/dev/null || true

    echo -e "${GREEN}User $username berhasil dihapus (sistem + record).${NC}"
}

# Renew user (manager)
renew_user_mgr() {
    read -p "Input Username yang ingin diperpanjang: " username
    [[ -z $username ]] && echo -e "${RED}Username kosong!${NC}" && return 1

    if ! id "$username" &>/dev/null; then
        echo -e "${RED}User tidak ditemukan di sistem.${NC}" && return 1
    fi

    read -p "Tambahkan masa aktif berapa hari?: " days
    days=${days:-30}

    current_exp=$(chage -l "$username" | grep "Account expires" | awk -F": " '{print $2}')
    if [[ "$current_exp" == "never" ]] || [[ -z "$current_exp" ]]; then
        base_date=$(date +"%Y-%m-%d")
    else
        base_date=$(date -d "$current_exp" +"%Y-%m-%d" 2>/dev/null || date +"%Y-%m-%d")
    fi

    new_exp=$(date -d "$base_date + $days days" +"%Y-%m-%d")
    sudo usermod -e "$new_exp" "$username"
    echo "$new_exp" | sudo tee "$DATA_DIR/$username.exp" >/dev/null

    echo -e "${GREEN}Renew berhasil!${NC}"
    echo "--------------------------------------------"
    echo -e " Username : ${YELLOW}$username${NC}"
    echo -e " Expired  : ${YELLOW}$new_exp${NC}"
    echo "--------------------------------------------"
}

# List users (manager)
list_users_mgr() {
    echo -e "${CYAN}Daftar user (sistem) & expiry (dari $DATA_DIR):${NC}"
    echo "--------------------------------------------"
    # show only users with UID >= 1000 (typical non-system) plus check exp files
    awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | while read u; do
        exp_file="$DATA_DIR/$u.exp"
        if [[ -f $exp_file ]]; then
            exp_date=$(cat "$exp_file")
            echo -e "$u - Exp: ${YELLOW}$exp_date${NC}"
        else
            echo -e "$u - Exp: ${YELLOW}never(or not recorded)${NC}"
        fi
    done
    echo "--------------------------------------------"
    echo -e "${CYAN}Plain recordfile: ${PASSFILE} (permission 600)${NC}"
}

# Auto-delete expired (to be called by cron)
auto_delete_expired() {
    today=$(date +%Y-%m-%d)
    for f in "$DATA_DIR"/*.exp 2>/dev/null; do
        [[ ! -f "$f" ]] && continue
        username=$(basename "$f" .exp)
        exp_date=$(cat "$f")
        # if exp_date less than today -> delete
        if [[ "$exp_date" < "$today" ]]; then
            echo "Deleting expired user: $username (expired $exp_date)"
            sudo userdel "$username" 2>/dev/null || true
            sudo sed -i "/^${username}:/d" "$PASSFILE" 2>/dev/null || true
            sudo rm -f "$DATA_DIR/$username.exp"
        fi
    done
}

# Setup cron job for daily auto-delete at 00:00 if not present
setup_cron() {
    local cronjob="0 0 * * * /bin/bash $(readlink -f "$0") --auto >/dev/null 2>&1"
    # install if not exist
    (crontab -l 2>/dev/null | grep -v -F "$CRON_MARKER" || true) >/tmp/current_cron.$$ 2>/dev/null
    if ! crontab -l 2>/dev/null | grep -q "$(echo "$cronjob" | sed 's/\//\\\//g')"; then
        (crontab -l 2>/dev/null; echo "$CRON_MARKER"; echo "$cronjob") | crontab -
    fi
    rm -f /tmp/current_cron.$$ 2>/dev/null || true
}

# If script is called with --auto, run auto delete and exit
if [[ "$1" == "--auto" ]]; then
    auto_delete_expired
    exit 0
fi

# Ensure cron is setup
setup_cron

# Manager CLI menu (runs after installer finishes)
echo
echo -e "${CYAN}==============================${NC}"
echo -e "${GREEN}   SOCKS5 MANAGER (combined)  ${NC}"
echo -e "${CYAN}==============================${NC}"
echo -e "1) Add User"
echo -e "2) Delete User"
echo -e "3) Renew User"
echo -e "4) List Users"
echo -e "5) Show /etc/danted/sockd.passwd (root only)"
echo -e "0) Exit"
echo -e "${CYAN}==============================${NC}"
read -p "Select menu: " opt_mgr

case $opt_mgr in
    1) add_user_mgr ;;
    2) delete_user_mgr ;;
    3) renew_user_mgr ;;
    4) list_users_mgr ;;
    5) echo -e "${YELLOW}File: $PASSFILE (permission 600)${NC}"; sudo cat "$PASSFILE" || true ;;
    0) echo "Exiting manager." ;;
    *) echo "Invalid option." ;;
esac

# ----------------------------
# END ADDED MANAGER
# ----------------------------
