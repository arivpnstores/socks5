#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}== REMOVE SOCKS5 (DANTED) OLD INSTALL ==${NC}"

# stop + disable service if exists
if systemctl list-unit-files | grep -q '^danted\.service'; then
  echo -e "${CYAN}Stop & disable danted...${NC}"
  systemctl stop danted 2>/dev/null || true
  systemctl disable danted 2>/dev/null || true
fi

# kill leftovers just in case
pkill -f sockd 2>/dev/null || true

echo -e "${CYAN}Remove packages...${NC}"
apt-get remove --purge -y danted apache2-utils 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true

echo -e "${CYAN}Delete configs & data...${NC}"
rm -f /etc/danted.conf 2>/dev/null || true
rm -rf /etc/danted 2>/dev/null || true
rm -rf /etc/socks5 2>/dev/null || true
rm -f /var/log/danted.log 2>/dev/null || true

# remove cron entries that mention socks5 / danted / sockd
echo -e "${CYAN}Clean cron (if any)...${NC}"
( crontab -l 2>/dev/null || true ) \
  | grep -vE 'socks5|danted|sockd|remove-socks5|socks5-manager' \
  | crontab - 2>/dev/null || true

# reload systemd
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

echo -e "${GREEN}DONE: SOCKS5 lama sudah dihapus total.${NC}"
echo -e "${CYAN}Cek port 1080 kosong:${NC} ss -lntup | grep :1080 || echo OK"
