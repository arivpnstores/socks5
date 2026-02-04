#!/bin/bash
# SOCKS5 Installer & Manager 
# Port: 1080
# Auth: username/password

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT=1080
DATA_DIR="/etc/socks5"
DATA_FILE="$DATA_DIR/users.db"
PASSFILE="/etc/danted/sockd.passwd"

mkdir -p $DATA_DIR
touch $DATA_FILE
chmod 600 $DATA_FILE

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Run as root!${NC}"
  exit 1
fi

install_danted() {
  echo -e "${CYAN}Installing SOCKS5...${NC}"
  apt update -y
  apt install -y danted apache2-utils
  systemctl stop danted

cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $PORT
external: eth0

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

  systemctl enable danted
  systemctl restart danted
  echo -e "${GREEN}SOCKS5 Installed on port $PORT${NC}"
}

add_user() {
  read -p "Username: " user
  read -p "Password: " pass
  read -p "Expire (days): " days

  exp=$(date -d "+$days days" +%Y-%m-%d)

  htpasswd -b $PASSFILE $user $pass
  echo "$user|$exp" >> $DATA_FILE
  systemctl restart danted

  echo -e "${GREEN}User created!${NC}"
  echo "Username: $user"
  echo "Password: $pass"
  echo "Expire: $exp"
}

del_user() {
  read -p "Username: " user
  sed -i "/^$user|/d" $DATA_FILE
  htpasswd -D $PASSFILE $user
  systemctl restart danted
  echo -e "${GREEN}User deleted!${NC}"
}

list_user() {
  echo -e "${CYAN}SOCKS5 USERS${NC}"
  while IFS="|" read u e; do
    echo "$u  ->  $e"
  done < $DATA_FILE
}

check_exp() {
  today=$(date +%s)
  while IFS="|" read u e; do
    exp=$(date -d "$e" +%s)
    if [[ $today -ge $exp ]]; then
      htpasswd -D $PASSFILE $u
      sed -i "/^$u|/d" $DATA_FILE
      echo "Expired removed: $u"
    fi
  done < $DATA_FILE
}

menu() {
clear
echo -e "${CYAN}SOCKS5 MANAGER${NC}"
echo "1. Install SOCKS5"
echo "2. Add User"
echo "3. Delete User"
echo "4. List User"
echo "5. Check Expired"
echo "0. Exit"
read -p "Choose: " opt

case $opt in
1) install_danted ;;
2) add_user ;;
3) del_user ;;
4) list_user ;;
5) check_exp ;;
0) exit ;;
*) echo "Invalid!" ;;
esac
read -p "Press Enter..."
menu
}

menu
