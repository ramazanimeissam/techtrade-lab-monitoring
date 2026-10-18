#!/usr/bin/env bash
# PLAN-200 L13 Lab-Kit (Prometheus + Grafana, Kennzahlen, Release ueberwachen)
# Baut auf dem fertigen L12-Template auf (R1 mit SNMPv3, Zabbix auf SRV-MON).
# Aufruf:  sudo bash l13.sh mon   (auf SRV-MON)
#          sudo bash l13.sh web   (auf SRV-WEB)
set -euo pipefail

KIT_URL="${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main}"
ROLE="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten."; exit 1; }
case "$ROLE" in mon|web) ;; *) echo "Aufruf: sudo bash l13.sh mon|web"; exit 1 ;; esac

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=300"
U=gns3
log(){ echo; echo "=== $* ==="; }

# SNMPv3-Zugang auf R1 (so wie beim Bau auf R1 eingetippt)
SNMP_USER=zbxmon
SNMP_AUTH=TechTrade-Auth1
SNMP_PRIV=TechTrade-Priv1

log "Cheatsheet L13"
wget -q "$KIT_URL/l13-cheatsheet.txt" -O /home/$U/lab-cheatsheet.txt
chown $U:$U /home/$U/lab-cheatsheet.txt

log "Paketquellen aktualisieren (ohne Upgrade)"
$APT update

# ====================================================================== SRV-MON
if [[ $ROLE == mon ]]; then
  log "iperf3 (Client fuer den Lasttest)"
  echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
  $APT install iperf3 jq

  log "Konfigurationsdateien /opt/monitoring/config (Link ~/monitoring)"
  M=/opt/monitoring
  mkdir -p $M/config

  cat > $M/config/prometheus.yml <<'EOF'
# Prometheus-Konfiguration TechTrade AG (SRV-MON)
# Pruefen:      prom-check
# Neu laden:    prom-reload

global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
EOF

  cat > $M/config/snmp-auth.yml <<'EOF'
# SNMP-Zugangsdaten fuer den snmp_exporter (SRV-MON)
# Neu laden:    snmp-reload
auths: {}
EOF

  cat > $M/config/blackbox.yml <<'EOF'
# Module des blackbox_exporter (SRV-MON)
modules:
  http_2xx:
    prober: http
    timeout: 5s

  shop_http:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      fail_if_body_not_matches_regexp: ["TechTrade Shop"]

  shop_https:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      fail_if_not_ssl: true
      tls_config:
        insecure_skip_verify: true
EOF

  cat > $M/docker-compose.yml <<'EOF'
services:
  prometheus:
    image: prom/prometheus:v3.14.0
    container_name: prometheus
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/config/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
    volumes:
      - /opt/monitoring/config:/config:ro
      - promdata:/prometheus

  snmp-exporter:
    image: prom/snmp-exporter:v0.30.1
    container_name: snmp-exporter
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/etc/snmp_exporter/snmp.yml
      - --config.file=/config/snmp-auth.yml
    volumes:
      - /opt/monitoring/config:/config:ro

  blackbox-exporter:
    image: prom/blackbox-exporter:v0.28.0
    container_name: blackbox-exporter
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/config/blackbox.yml
    volumes:
      - /opt/monitoring/config:/config:ro

  grafana:
    image: grafana/grafana:13.1.6
    container_name: grafana
    restart: unless-stopped
    network_mode: host
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: Gns3456
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_NEWS_NEWS_FEED_ENABLED: "false"
    volumes:
      - grafanadata:/var/lib/grafana

volumes:
  promdata:
  grafanadata:
EOF

  chmod 755 $M $M/config
  chmod 644 $M/config/*.yml
  chown $U:$U $M/config/*.yml
  ln -sfn $M/config /home/$U/monitoring
  chown -h $U:$U /home/$U/monitoring

  log "Hilfsbefehle prom-check, prom-reload, snmp-reload"
  cat > /usr/local/bin/prom-check <<'EOF'
#!/bin/sh
# Prueft ~/monitoring/prometheus.yml auf Fehler
docker exec prometheus promtool check config /config/prometheus.yml
EOF
  cat > /usr/local/bin/prom-reload <<'EOF'
#!/bin/sh
# Laedt ~/monitoring/prometheus.yml neu (ohne Neustart)
OUT=$(mktemp)
CODE=$(curl -s -o "$OUT" -w '%{http_code}' -X POST http://localhost:9090/-/reload)
if [ "$CODE" = 200 ]; then echo "OK: Prometheus hat die Konfiguration neu geladen."
else echo "FEHLER ($CODE):"; cat "$OUT"; echo; rm -f "$OUT"; exit 1; fi
rm -f "$OUT"
EOF
  cat > /usr/local/bin/snmp-reload <<'EOF'
#!/bin/sh
# Laedt ~/monitoring/snmp-auth.yml neu (ohne Neustart)
OUT=$(mktemp)
CODE=$(curl -s -o "$OUT" -w '%{http_code}' -X POST http://localhost:9116/-/reload)
if [ "$CODE" = 200 ]; then echo "OK: snmp_exporter hat die Konfiguration neu geladen."
else echo "FEHLER ($CODE):"; cat "$OUT"; echo; rm -f "$OUT"; exit 1; fi
rm -f "$OUT"
EOF
  chmod 755 /usr/local/bin/prom-check /usr/local/bin/prom-reload /usr/local/bin/snmp-reload

  log "Prometheus, Exporter und Grafana starten (Images laden, dauert)"
  systemctl enable --now docker
  docker compose -f $M/docker-compose.yml pull
  docker compose -f $M/docker-compose.yml up -d

  log "Warten auf Prometheus und Grafana (max. 3 Min)"
  for i in $(seq 1 36); do
    curl -fs http://localhost:9090/-/ready >/dev/null && curl -fs http://localhost:3000/api/health >/dev/null && break
    sleep 5
  done

  log "Zabbix: R1 und SRV-WEB aufnehmen (Endzustand L12)"
  API=http://localhost:8080/api_jsonrpc.php
  TOKEN=""
  zapi(){ curl -s -H 'Content-Type: application/json-rpc' ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -d "$1" $API; }
  for i in $(seq 1 30); do
    TOKEN=$(zapi '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' | jq -r '.result // empty')
    [[ -n $TOKEN ]] && break; sleep 5
  done
  [[ -n $TOKEN ]] || { echo "Zabbix-API nicht erreichbar. Laeuft Zabbix? (cd /opt/zabbix && sudo docker compose up -d)"; exit 1; }

  gid(){ # Gruppe holen oder anlegen
    local id; id=$(zapi "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.get\",\"params\":{\"filter\":{\"name\":[\"$1\"]},\"output\":[\"groupid\"]},\"id\":2}" | jq -r '.result[0].groupid // empty')
    [[ -z $id ]] && id=$(zapi "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.create\",\"params\":{\"name\":\"$1\"},\"id\":3}" | jq -r '.result.groupids[0]')
    echo "$id"; }
  tid(){ zapi "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"host\":[\"$1\"]},\"output\":[\"templateid\"]},\"id\":4}" | jq -r '.result[0].templateid'; }
  hid(){ zapi "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$1\"]},\"output\":[\"hostid\"]},\"id\":5}" | jq -r '.result[0].hostid // empty'; }

  G_NET=$(gid TechTrade/Network); G_SRV=$(gid TechTrade/Server)
  T_SNMP=$(tid "Linux by SNMP");  T_AGT=$(tid "Linux by Zabbix agent")

  if [[ -z $(hid R1) ]]; then
    zapi "{\"jsonrpc\":\"2.0\",\"method\":\"host.create\",\"params\":{\"host\":\"R1\",
      \"groups\":[{\"groupid\":\"$G_NET\"}],\"templates\":[{\"templateid\":\"$T_SNMP\"}],
      \"interfaces\":[{\"type\":2,\"main\":1,\"useip\":1,\"ip\":\"10.10.100.1\",\"dns\":\"\",\"port\":\"161\",
        \"details\":{\"version\":3,\"bulk\":1,\"securityname\":\"$SNMP_USER\",\"securitylevel\":2,
          \"authprotocol\":1,\"authpassphrase\":\"$SNMP_AUTH\",\"privprotocol\":1,\"privpassphrase\":\"$SNMP_PRIV\",\"contextname\":\"\"}}]},\"id\":6}" | jq -c '.error // "R1 angelegt"'
  fi
  if [[ -z $(hid SRV-WEB) ]]; then
    zapi "{\"jsonrpc\":\"2.0\",\"method\":\"host.create\",\"params\":{\"host\":\"SRV-WEB\",
      \"groups\":[{\"groupid\":\"$G_SRV\"}],\"templates\":[{\"templateid\":\"$T_AGT\"}],
      \"interfaces\":[{\"type\":1,\"main\":1,\"useip\":1,\"ip\":\"10.10.20.13\",\"dns\":\"\",\"port\":\"10050\"}]},\"id\":7}" | jq -c '.error // "SRV-WEB angelegt"'
    WEB=$(hid SRV-WEB)
    zapi "{\"jsonrpc\":\"2.0\",\"method\":\"httptest.create\",\"params\":{\"name\":\"Shop\",\"hostid\":\"$WEB\",\"delay\":\"1m\",
      \"steps\":[{\"name\":\"Startseite\",\"url\":\"http://10.10.20.13/\",\"status_codes\":\"200\",\"required\":\"TechTrade Shop\",\"no\":1}]},\"id\":8}" | jq -c '.error // "Web-Szenario Shop angelegt"'
    zapi '{"jsonrpc":"2.0","method":"trigger.create","params":{"description":"Shop nicht erreichbar","expression":"last(/SRV-WEB/web.test.fail[Shop])<>0","priority":4},"id":9}' | jq -c '.error // "Trigger angelegt"'
  fi

  log "Zabbix: Discovery sofort ausfuehren"
  for H in R1 SRV-WEB; do
    for R in $(zapi "{\"jsonrpc\":\"2.0\",\"method\":\"discoveryrule.get\",\"params\":{\"hostids\":[\"$(hid $H)\"],\"output\":[\"itemid\"]},\"id\":10}" | jq -r '.result[].itemid'); do
      zapi "{\"jsonrpc\":\"2.0\",\"method\":\"task.create\",\"params\":[{\"type\":6,\"request\":{\"itemid\":\"$R\"}}],\"id\":11}" >/dev/null
    done
  done
  zapi '{"jsonrpc":"2.0","method":"user.logout","params":{},"id":12}' >/dev/null || true

  log "Pruefskript ~/lab/l13-verify.sh"
  mkdir -p /home/$U/lab
  wget -q "$KIT_URL/l13-verify.sh" -O /home/$U/lab/l13-verify.sh
  chmod +x /home/$U/lab/l13-verify.sh
  chown -R $U:$U /home/$U/lab
fi

# ====================================================================== SRV-WEB
if [[ $ROLE == web ]]; then
  log "node_exporter und iperf3"
  echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
  $APT install prometheus-node-exporter iperf3
  systemctl enable --now prometheus-node-exporter

  cat > /etc/systemd/system/iperf3-lab.service <<'EOF'
[Unit]
Description=Lab: iperf3-Server fuer Lasttests
After=network-online.target

[Service]
ExecStart=/usr/bin/iperf3 -s
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now iperf3-lab.service

  log "nginx: Einbindung fuer Release-Konfiguration"
  mkdir -p /etc/nginx/techtrade
  cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/ssl/techtrade/shop.crt;
    ssl_certificate_key /etc/ssl/techtrade/shop.key;
    root  /var/www/shop;
    index index.html;
    include /etc/nginx/techtrade/*.conf;
}
EOF

  log "Shop-Pakete 1.0 (neu gebaut) und 1.2 bauen"
  mkdir -p /opt/lab/release
  mkpkg(){ # $1=Version  $2=Titel  $3=Text  $4=fehlerhaft(0|1)
    local d; d=$(mktemp -d)
    mkdir -p "$d/DEBIAN" "$d/var/www/shop"
    cat > "$d/DEBIAN/control" <<EOF
Package: techtrade-shop
Version: $1
Architecture: all
Maintainer: TechTrade IT <it@techtrade.lab>
Description: TechTrade Online-Shop (Frontend) Release $1
EOF
    cat > "$d/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
fi
EOF
    chmod 755 "$d/DEBIAN/postinst"
    cat > "$d/var/www/shop/index.html" <<EOF
<!doctype html>
<html lang="de"><head><meta charset="utf-8"><title>$2</title></head>
<body><h1>$2</h1><p>$3</p><p>Release $1</p></body></html>
EOF
    if [[ $4 == 1 ]]; then
      # Fehler in 1.2: der neue Lastverteiler-Baustein beantwortet rund 20 % der Anfragen mit 503
      mkdir -p "$d/etc/nginx/conf.d" "$d/etc/nginx/techtrade"
      cat > "$d/etc/nginx/conf.d/techtrade-shop.conf" <<'EOF'
# techtrade-shop 1.2: Verteilung der Anfragen
split_clients "${request_id}" $techtrade_backend_down {
    20%  1;
    *    0;
}
EOF
      cat > "$d/etc/nginx/techtrade/release.conf" <<'EOF'
# techtrade-shop 1.2
if ($techtrade_backend_down) { return 503; }
EOF
    fi
    dpkg-deb --build --root-owner-group "$d" "/opt/lab/release/techtrade-shop_$1_all.deb" >/dev/null
    rm -rf "$d"
  }
  mkpkg 1.0 "TechTrade Shop" "Willkommen im TechTrade Shop. Unser Sortiment: Notebooks, Monitore, Zubehoer." 0
  mkpkg 1.2 "TechTrade Shop" "Willkommen im TechTrade Shop. Neu: Wunschliste und schnellere Produktsuche." 1
  dpkg -i /opt/lab/release/techtrade-shop_1.0_all.deb
  nginx -t
  systemctl restart nginx
fi

log "FERTIG ($ROLE)"
if [[ $ROLE == mon ]]; then
  echo "Prometheus: http://localhost:9090   Grafana: http://localhost:3000 (admin / Gns3456)"
  echo "Pruefen, sobald SRV-WEB fertig ist:  bash ~/lab/l13-verify.sh"
fi
