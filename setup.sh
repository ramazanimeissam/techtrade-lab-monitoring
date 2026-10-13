#!/usr/bin/env bash
# PLAN-200 L12 Lab-Kit (SNMP + Zabbix, Wartung)
# Aufruf:  sudo bash setup.sh mon   (auf SRV-MON)
#          sudo bash setup.sh web   (auf SRV-WEB)
set -euo pipefail

KIT_URL="${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main}"
ROLE="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten."; exit 1; }

case "$ROLE" in
  mon) HOST=SRV-MON; ADDR=10.10.100.20/24; GW=10.10.100.1 ;;
  web) HOST=SRV-WEB; ADDR=10.10.20.13/24;  GW=10.10.20.1  ;;
  *)   echo "Aufruf: sudo bash setup.sh mon|web"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=300"
U=gns3
log(){ echo; echo "=== $* ==="; }

# ---------------------------------------------------------------- gemeinsam
log "Hostname und Netz ($HOST, $ADDR)"
hostnamectl set-hostname "$HOST"
if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1 $HOST/" /etc/hosts
else echo "127.0.1.1 $HOST" >> /etc/hosts; fi
rm -f /etc/netplan/*.yaml
cat > /etc/netplan/01-dhcp.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      dhcp4: false
      addresses: [$ADDR]
      routes: [{to: default, via: $GW}]
      nameservers: {addresses: [1.1.1.1, 8.8.8.8]}
EOF
chmod 600 /etc/netplan/01-dhcp.yaml
netplan apply
sleep 5

log "Automatische Updates deaktivieren"
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

log "Basispakete"
$APT update
$APT install curl wget tcpdump snmp openssl ca-certificates
# Ubuntu laedt standardmaessig keine MIBs -> symbolische OIDs (IF-MIB::ifName) aktivieren
sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf

log "Zabbix-Repository 7.0 LTS"
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb
$APT update

log "Cheatsheet"
wget -q "$KIT_URL/lab-cheatsheet.txt" -O /home/$U/lab-cheatsheet.txt
chown $U:$U /home/$U/lab-cheatsheet.txt

# ---------------------------------------------------------------- SRV-MON
if [[ $ROLE == mon ]]; then
  log "Werkzeuge SRV-MON"
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  $APT install docker.io docker-compose-v2 zabbix-get wireshark
  dpkg -s libreoffice-calc >/dev/null 2>&1 || $APT install libreoffice-calc
  usermod -aG docker,wireshark $U

  log "Zabbix 7.0 in Docker Compose"
  mkdir -p /opt/zabbix
  cat > /opt/zabbix/docker-compose.yml <<'EOF'
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix
      POSTGRES_DB: zabbix
    volumes:
      - pgdata:/var/lib/postgresql/data

  server:
    image: zabbix/zabbix-server-pgsql:ubuntu-7.0-latest
    restart: unless-stopped
    depends_on: [db]
    environment:
      DB_SERVER_HOST: db
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix
      POSTGRES_DB: zabbix
    ports:
      - "10051:10051"

  web:
    image: zabbix/zabbix-web-nginx-pgsql:ubuntu-7.0-latest
    restart: unless-stopped
    depends_on: [db, server]
    environment:
      ZBX_SERVER_HOST: server
      DB_SERVER_HOST: db
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix
      POSTGRES_DB: zabbix
      PHP_TZ: Europe/Zurich
    ports:
      - "8080:8080"

volumes:
  pgdata:
EOF
  systemctl enable --now docker
  docker compose -f /opt/zabbix/docker-compose.yml up -d

  log "Warten auf Zabbix-Frontend (max. 5 Min)"
  for i in $(seq 1 60); do
    curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ | grep -q 200 && break
    sleep 5
  done

  log "Standard-Host 'Zabbix server' entfernen (Startzustand: keine Hosts)"
  API=http://localhost:8080/api_jsonrpc.php
  zapi(){ curl -s -H 'Content-Type: application/json-rpc' ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -d "$1" $API; }
  TOKEN=""
  for i in $(seq 1 30); do
    TOKEN=$(zapi '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result",""))' 2>/dev/null || true)
    [[ -n $TOKEN ]] && break; sleep 5
  done
  HID=$(zapi '{"jsonrpc":"2.0","method":"host.get","params":{"filter":{"host":["Zabbix server"]},"output":["hostid"]},"id":2}' \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["hostid"] if r else "")')
  [[ -n $HID ]] && zapi "{\"jsonrpc\":\"2.0\",\"method\":\"host.delete\",\"params\":[\"$HID\"],\"id\":3}" >/dev/null
  zapi '{"jsonrpc":"2.0","method":"user.logout","params":{},"id":4}' >/dev/null || true

  log "Lab-Daten"
  mkdir -p /home/$U/lab
  wget -q "$KIT_URL/shop_last_7x24.csv" -O /home/$U/lab/shop_last_7x24.csv
  wget -q "$KIT_URL/verify.sh"          -O /home/$U/lab/verify.sh
  chmod +x /home/$U/lab/verify.sh
  chown -R $U:$U /home/$U/lab
fi

# ---------------------------------------------------------------- SRV-WEB
if [[ $ROLE == web ]]; then
  log "nginx und Zabbix agent2"
  $APT install nginx zabbix-agent2

  log "Zertifikat (wird bei jedem Boot neu mit 20 Tagen Laufzeit ausgestellt)"
  mkdir -p /etc/ssl/techtrade
  cat > /usr/local/sbin/lab-cert.sh <<'EOF'
#!/bin/sh
openssl req -x509 -newkey rsa:2048 -nodes -days 20 \
  -subj "/CN=shop.techtrade.lab/O=TechTrade AG" \
  -keyout /etc/ssl/techtrade/shop.key -out /etc/ssl/techtrade/shop.crt 2>/dev/null
chmod 644 /etc/ssl/techtrade/shop.crt
chmod 600 /etc/ssl/techtrade/shop.key
EOF
  chmod +x /usr/local/sbin/lab-cert.sh
  cat > /etc/systemd/system/lab-cert.service <<'EOF'
[Unit]
Description=Lab: Shop-Zertifikat mit kurzer Laufzeit ausstellen
Before=nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lab-cert.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable lab-cert.service
  /usr/local/sbin/lab-cert.sh

  log "Shop-Pakete techtrade-shop 1.0 und 1.1 bauen"
  mkdir -p /opt/lab/release
  mkpkg(){ # $1=Version  $2=Titel  $3=Text
    local d; d=$(mktemp -d)
    mkdir -p "$d/DEBIAN" "$d/var/www/shop"
    cat > "$d/DEBIAN/control" <<EOF
Package: techtrade-shop
Version: $1
Architecture: all
Maintainer: TechTrade IT <it@techtrade.lab>
Description: TechTrade Online-Shop (Frontend) Release $1
EOF
    cat > "$d/var/www/shop/index.html" <<EOF
<!doctype html>
<html lang="de"><head><meta charset="utf-8"><title>$2</title></head>
<body><h1>$2</h1><p>$3</p><p>Release $1</p></body></html>
EOF
    dpkg-deb --build --root-owner-group "$d" "/opt/lab/release/techtrade-shop_$1_all.deb" >/dev/null
    rm -rf "$d"
  }
  mkpkg 1.0 "TechTrade Shop" "Willkommen im TechTrade Shop. Unser Sortiment: Notebooks, Monitore, Zubehoer."
  mkpkg 1.1 "TechTrade Online" "Fehler: Produktkatalog konnte nicht geladen werden (template catalog.tpl not found)."
  $APT install /opt/lab/release/techtrade-shop_1.0_all.deb

  log "nginx: HTTP und HTTPS auf /var/www/shop"
  cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/ssl/techtrade/shop.crt;
    ssl_certificate_key /etc/ssl/techtrade/shop.key;
    root  /var/www/shop;
    index index.html;
}
EOF
  nginx -t
  systemctl enable nginx
  systemctl restart nginx

  log "Zabbix agent2 konfigurieren"
  C=/etc/zabbix/zabbix_agent2.conf
  sed -i 's/^Server=.*/Server=10.10.100.20/'             $C
  sed -i 's/^ServerActive=.*/ServerActive=10.10.100.20/' $C
  sed -i 's/^Hostname=.*/Hostname=SRV-WEB/'              $C
  grep -q '^Timeout=' $C && sed -i 's/^Timeout=.*/Timeout=10/' $C || echo 'Timeout=10' >> $C
  systemctl enable zabbix-agent2
  systemctl restart zabbix-agent2
fi

log "FERTIG ($HOST)"
if [[ $ROLE == mon ]]; then
  echo "Zabbix: http://localhost:8080  (Admin / zabbix)"
  echo "Pruefen, sobald SRV-WEB fertig ist:  bash ~/lab/verify.sh"
fi
echo "Abmelden und neu anmelden, damit Gruppen (docker, wireshark) greifen."
