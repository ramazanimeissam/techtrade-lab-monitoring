#!/usr/bin/env bash
# PLAN-200 L14 Lab-Kit (Syslog, Alerting, Überwachung sicherstellen)
# Baut auf dem L13-Template auf. Führt zuerst l13.sh aus (bereinigt ältere
# Template-Stände), setzt dann den L13-Endzustand und ergänzt L14.
# Aufruf:  sudo bash l14.sh mon   (auf SRV-MON)
#          sudo bash l14.sh web   (auf SRV-WEB)
set -euo pipefail

KIT_URL="${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main}"
ROLE="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten."; exit 1; }
case "$ROLE" in mon|web) ;; *) echo "Aufruf: sudo bash l14.sh mon|web"; exit 1 ;; esac

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=300"
U=gns3
log(){ echo; echo "=== $* ==="; }

log "Schritt 1: l13.sh $ROLE (bereinigt den Template-Stand)"
wget -q "$KIT_URL/l13.sh" -O /tmp/l13.sh
bash /tmp/l13.sh "$ROLE"
rm -f /tmp/l13.sh

log "Schritt 2: L14"

# ====================================================================== SRV-MON
if [[ $ROLE == mon ]]; then
  M=/opt/monitoring

  log "syslog-ng installieren (ersetzt rsyslog auf SRV-MON, noch kein Empfang)"
  $APT install syslog-ng-core netcat-openbsd
  systemctl enable --now syslog-ng

  log "Prometheus: L13-Endzustand plus Anbindung Alertmanager"
  cat > /etc/prometheus/prometheus.yml <<'EOF'
# Prometheus-Konfiguration TechTrade AG (SRV-MON)
# Bearbeiten:   sudo nano /etc/prometheus/prometheus.yml
# Prüfen:       sudo docker exec prometheus promtool check config /config/prometheus.yml
# Neu laden:    curl -X POST http://localhost:9090/-/reload

global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: node
    static_configs:
      - targets: ['10.10.20.13:9100']

  - job_name: snmp
    metrics_path: /snmp
    params:
      module: [if_mib]
      auth: [techtrade_v3]
    static_configs:
      - targets: ['10.10.100.1']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9116

  - job_name: shop
    scrape_interval: 5s
    metrics_path: /probe
    params:
      module: [shop_http]
    static_configs:
      - targets: ['http://10.10.20.13/']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9115

  - job_name: shop_tls
    metrics_path: /probe
    params:
      module: [shop_https]
    static_configs:
      - targets: ['https://10.10.20.13/']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9115
EOF

  cat > /etc/prometheus/snmp-auth.yml <<'EOF'
# SNMP-Zugangsdaten für den snmp_exporter (SRV-MON)
# Bearbeiten:   sudo nano /etc/prometheus/snmp-auth.yml
# Neu laden:    curl -X POST http://localhost:9116/-/reload
auths:
  techtrade_v3:
    version: 3
    username: zbxmon
    security_level: authPriv
    auth_protocol: SHA
    password: TechTrade-Auth1
    priv_protocol: AES
    priv_password: TechTrade-Priv1
EOF

  log "Alertmanager: Mail an Mailpit"
  mkdir -p /etc/alertmanager
  cat > /etc/alertmanager/alertmanager.yml <<'EOF'
# Alertmanager-Konfiguration TechTrade AG (SRV-MON)
# Bearbeiten:   sudo nano /etc/alertmanager/alertmanager.yml
# Prüfen:       sudo docker exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
# Neu laden:    curl -X POST http://localhost:9093/-/reload

global:
  smtp_smarthost: 'localhost:1025'
  smtp_from: 'alertmanager@techtrade.lab'
  smtp_require_tls: false

route:
  receiver: betrieb
  group_by: [alertname]
  group_wait: 30s
  group_interval: 1m
  repeat_interval: 1h

receivers:
  - name: betrieb
    email_configs:
      - to: 'betrieb@techtrade.lab'
        send_resolved: true
EOF

  log "Loki: Logspeicher mit Regelauswertung"
  mkdir -p /etc/loki/rules/fake
  cat > /etc/loki/loki.yml <<'EOF'
# Loki-Konfiguration TechTrade AG (SRV-MON) - nur lesen
# Alarmregeln auf Logs:  /etc/loki/rules/fake/*.yml
# ("fake" ist der Mandantenname, wenn Loki ohne Anmeldung läuft)
# Loki liest neue oder geänderte Regeldateien selbst ein (ca. 1 Min).

auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://localhost:9093
  enable_api: true
  evaluation_interval: 15s
  rule_path: /loki/rules-temp
  storage:
    type: local
    local:
      directory: /etc/loki/rules

analytics:
  reporting_enabled: false
EOF

  log "Alloy: nimmt Syslog von syslog-ng an und schreibt in Loki"
  mkdir -p /etc/alloy
  cat > /etc/alloy/config.alloy <<'EOF'
// Grafana Alloy (SRV-MON) - nur lesen
// Nimmt Syslog-Meldungen von syslog-ng an (TCP 127.0.0.1:1514, RFC 5424)
// und schreibt sie mit Labels (host, app, severity, facility) in Loki.

loki.source.syslog "von_syslogng" {
  listener {
    address  = "127.0.0.1:1514"
    protocol = "tcp"
    labels   = { job = "syslog" }
  }
  relabel_rules = loki.relabel.syslog.rules
  forward_to    = [loki.write.lokal.receiver]
}

loki.relabel "syslog" {
  forward_to = []
  rule {
    source_labels = ["__syslog_message_hostname"]
    target_label  = "host"
  }
  rule {
    source_labels = ["__syslog_message_app_name"]
    target_label  = "app"
  }
  rule {
    source_labels = ["__syslog_message_severity"]
    target_label  = "severity"
  }
  rule {
    source_labels = ["__syslog_message_facility"]
    target_label  = "facility"
  }
}

loki.write "lokal" {
  endpoint {
    url = "http://localhost:3100/loki/api/v1/push"
  }
}
EOF

  chmod 755 /etc/alertmanager /etc/loki /etc/loki/rules /etc/loki/rules/fake /etc/alloy
  chmod 644 /etc/prometheus/*.yml /etc/alertmanager/*.yml /etc/loki/loki.yml /etc/alloy/config.alloy

  log "Compose: Alertmanager, Mailpit, Loki, Alloy ergänzen"
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
      - /etc/prometheus:/config:ro
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
      - /etc/prometheus:/config:ro

  blackbox-exporter:
    image: prom/blackbox-exporter:v0.28.0
    container_name: blackbox-exporter
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/config/blackbox.yml
    volumes:
      - /etc/prometheus:/config:ro

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

  alertmanager:
    image: prom/alertmanager:v0.30.1
    container_name: alertmanager
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --storage.path=/alertmanager
    volumes:
      - /etc/alertmanager:/etc/alertmanager:ro
      - amdata:/alertmanager

  mailpit:
    image: axllent/mailpit:v1.31.6
    container_name: mailpit
    restart: unless-stopped
    network_mode: host

  loki:
    image: grafana/loki:3.6.14
    container_name: loki
    restart: unless-stopped
    network_mode: host
    command:
      - -config.file=/etc/loki/loki.yml
    volumes:
      - /etc/loki:/etc/loki:ro
      - lokidata:/loki

  alloy:
    image: grafana/alloy:v1.17.1
    container_name: alloy
    restart: unless-stopped
    network_mode: host
    command:
      - run
      - --server.http.listen-addr=127.0.0.1:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - /etc/alloy:/etc/alloy:ro
      - alloydata:/var/lib/alloy/data

volumes:
  promdata:
  grafanadata:
  amdata:
  lokidata:
  alloydata:
EOF

  log "Images laden und starten (dauert)"
  docker compose -f $M/docker-compose.yml pull
  docker compose -f $M/docker-compose.yml up -d

  log "Warten auf die Dienste (max. 3 Min)"
  for i in $(seq 1 36); do
    curl -fs http://localhost:9090/-/ready >/dev/null \
      && curl -fs http://localhost:9093/-/ready >/dev/null \
      && curl -fs http://localhost:3100/ready >/dev/null \
      && curl -fs http://localhost:3000/api/health >/dev/null && break
    sleep 5
  done

  log "Konfiguration neu einlesen"
  curl -fs -X POST http://localhost:9116/-/reload || true
  curl -fs -X POST http://localhost:9090/-/reload || true

  log "Grafana: Datenquelle prometheus (Endzustand L13)"
  if ! curl -fs -u admin:Gns3456 http://localhost:3000/api/datasources/name/prometheus >/dev/null; then
    curl -fs -u admin:Gns3456 -H 'Content-Type: application/json' \
      -d '{"name":"prometheus","type":"prometheus","url":"http://localhost:9090","access":"proxy","isDefault":true}' \
      http://localhost:3000/api/datasources >/dev/null && echo "Datenquelle prometheus angelegt"
  fi

  log "Cheatsheet und Prüfskript"
  if wget -q "$KIT_URL/l14-cheatsheet.txt" -O /home/$U/lab-cheatsheet.txt; then
    echo "Cheatsheet L14 geladen"
  else
    echo "HINWEIS: l14-cheatsheet.txt noch nicht im Repo - vor dem Einfrieren nachladen"
  fi
  chown $U:$U /home/$U/lab-cheatsheet.txt 2>/dev/null || true
  rm -f /home/$U/lab/l13-verify.sh
  mkdir -p /home/$U/lab
  wget -q "$KIT_URL/l14-verify.sh" -O /home/$U/lab/l14-verify.sh
  chmod +x /home/$U/lab/l14-verify.sh
  chown -R $U:$U /home/$U/lab
fi

# ====================================================================== SRV-WEB
if [[ $ROLE == web ]]; then
  log "SSH-Server (für den Test fehlgeschlagener Anmeldungen)"
  $APT install openssh-server
  systemctl enable --now ssh

  log "netem für Störungstests (Verzögerung, Verlust)"
  if ! modprobe sch_netem 2>/dev/null; then
    $APT install "linux-modules-extra-$(uname -r)" || true
    modprobe sch_netem
  fi
  echo sch_netem > /etc/modules-load.d/netem.conf

  log "Cheatsheet"
  if wget -q "$KIT_URL/l14-cheatsheet.txt" -O /home/$U/lab-cheatsheet.txt; then
    echo "Cheatsheet L14 geladen"
  else
    echo "HINWEIS: l14-cheatsheet.txt noch nicht im Repo - vor dem Einfrieren nachladen"
  fi
  chown $U:$U /home/$U/lab-cheatsheet.txt 2>/dev/null || true
fi

log "FERTIG L14 ($ROLE)"
if [[ $ROLE == mon ]]; then
  echo "Prometheus :9090  Alertmanager :9093  Mailpit http://localhost:8025"
  echo "Grafana    :3000 (admin / Gns3456)   Zabbix :8080"
  echo "Prüfen, sobald SRV-WEB fertig ist:  bash ~/lab/l14-verify.sh"
fi
