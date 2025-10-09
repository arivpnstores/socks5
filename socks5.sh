#!/bin/bash
# SOCKS5 User Manager (Add / Delete / Renew / Auto Expire)
# Author: Ari Setiawan - Modified by ChatGPT GPT-5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DATA_DIR="/etc/shock5"
[[ ! -d $DATA_DIR ]] && mkdir -p $DATA_DIR

function url_encode() {
    local raw="$1" encoded=""
    for ((i=0; i<${#raw}; i++)); do
        char="${raw:i:1}"
        case "$char" in
            [a-zA-Z0-9._~-]) encoded+="$char" ;;
            *) encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    echo "$encoded"
}

function add_user() {
    echo -e "${CYAN}Input Username:${NC}"
    read username
    [[ -z $username ]] && echo -e "${RED}Username tidak boleh kosong!${NC}" && exit 1

    if id "$username" &>/dev/null; then
        echo -e "${RED}User $username sudah ada!${NC}"
        exit 1
    fi

    echo -e "${CYAN}Input Password:${NC}"
    read -s password
    echo -e "${CYAN}Input Masa Aktif (hari):${NC}"
    read days

    exp_date=$(date -d "$days days" +"%Y-%m-%d")
    sudo useradd -e "$exp_date" -s /usr/sbin/nologin "$username"
    echo "$username:$password" | sudo chpasswd

    echo "$exp_date" > "$DATA_DIR/$username.exp"
    proxy_ip=$(hostname -I | awk '{print $1}')
    port=$(grep -oP 'internal: 0.0.0.0 port = \K[0-9]+' /etc/danted.conf 2>/dev/null || echo 1080)

    echo -e "${GREEN}\nSOCKS5 Account Created Successfully!${NC}"
    echo -e "--------------------------------------------"
    echo -e " Username : ${YELLOW}$username${NC}"
    echo -e " Password : ${YELLOW}$password${NC}"
    echo -e " Expired  : ${YELLOW}$exp_date${NC}"
    echo -e "--------------------------------------------"
    echo -e "${CYAN}SOCKS5 : ${GREEN}${proxy_ip}:${port}:${username}:${password}${NC}"
    echo -e "--------------------------------------------"
}

function delete_user() {
    echo -e "${CYAN}Input Username yang ingin dihapus:${NC}"
    read username
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}User tidak ditemukan!${NC}"
        exit 1
    fi
    sudo userdel "$username"
    rm -f "$DATA_DIR/$username.exp"
    echo -e "${GREEN}User $username berhasil dihapus.${NC}"
}

function renew_user() {
    echo -e "${CYAN}Input Username yang ingin diperpanjang:${NC}"
    read username
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}User tidak ditemukan!${NC}"
        exit 1
    fi
    echo -e "${CYAN}Tambahkan masa aktif berapa hari?:${NC}"
    read days

    current_exp=$(chage -l "$username" | grep "Account expires" | awk -F": " '{print $2}')
    [[ $current_exp == "never" ]] && current_exp=$(date +"%Y-%m-%d")

    new_exp=$(date -d "$current_exp + $days days" +"%Y-%m-%d")
    sudo usermod -e "$new_exp" "$username"
    echo "$new_exp" > "$DATA_DIR/$username.exp"

    echo -e "${GREEN}Renew berhasil!${NC}"
    echo -e "--------------------------------------------"
    echo -e " Username : ${YELLOW}$username${NC}"
    echo -e " Expired  : ${YELLOW}$new_exp${NC}"
    echo -e "--------------------------------------------"
}

function list_users() {
    echo -e "${CYAN}Daftar User SOCKS5:${NC}"
    echo "--------------------------------------------"
    for u in $(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd); do
        exp_file="$DATA_DIR/$u.exp"
        if [[ -f $exp_file ]]; then
            exp_date=$(cat "$exp_file")
            echo -e "$u - Exp: ${YELLOW}$exp_date${NC}"
        fi
    done
    echo "--------------------------------------------"
}

function auto_delete_expired() {
    today=$(date +%Y-%m-%d)
    for user in $(ls $DATA_DIR/*.exp 2>/dev/null); do
        username=$(basename "$user" .exp)
        exp_date=$(cat "$user")
        if [[ "$exp_date" < "$today" ]]; then
            echo "Deleting expired user: $username ($exp_date)"
            userdel "$username" 2>/dev/null
            rm -f "$DATA_DIR/$username.exp"
        fi
    done
}

# Setup cron auto delete expired
if ! crontab -l | grep -q "shock5 --auto"; then
    (crontab -l 2>/dev/null; echo "0 0 * * * /usr/bin/shock5 --auto >/dev/null 2>&1") | crontab -
fi

# Handle auto mode (for cron)
if [[ "$1" == "--auto" ]]; then
    auto_delete_expired
    exit 0
fi

clear
echo -e "${CYAN}=====================================${NC}"
echo -e "${GREEN}        SOCKS5 ACCOUNT MANAGER       ${NC}"
echo -e "${CYAN}=====================================${NC}"
echo -e "1) Add User"
echo -e "2) Delete User"
echo -e "3) Renew User"
echo -e "4) List Users"
echo -e "0) Exit"
echo -e "${CYAN}=====================================${NC}"
read -p "Select menu: " opt

case $opt in
    1) add_user ;;
    2) delete_user ;;
    3) renew_user ;;
    4) list_users ;;
    0) exit ;;
    *) echo "Invalid option." ;;
esac
