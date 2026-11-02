#!/usr/bin/env bash
# PLAN-200 L16 Lab-Kit (DNS mit BIND 9, Wireshark, Kennzahlen auswerten)
# Stand 01.11.2026. Baut auf dem eingefrorenen L15-Template auf (Duplikat) plus neue VM SRV-DNS.
# Aufruf:  sudo bash l16.sh dns   (auf SRV-DNS, neue VM)
#          sudo bash l16.sh web   (auf SRV-WEB)
#          sudo bash l16.sh mon   (auf SRV-MON)
# Reihenfolge egal. Danach auf jedem System:  bash ~/lab/l16-verify.sh
set -euo pipefail

KIT_URL="${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main}"
ROLE="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten."; exit 1; }
case "$ROLE" in dns|web|mon) ;; *) echo "Aufruf: sudo bash l16.sh dns|web|mon"; exit 1 ;; esac

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=300"
U=gns3
log(){ echo; echo "=== $* ==="; }

wireshark_install(){
  log "Wireshark und tshark (Packet Capture ohne sudo für $U)"
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  $APT install wireshark tshark tcpdump
  dpkg-reconfigure -f noninteractive wireshark-common
  usermod -aG wireshark $U
}

# ====================================================================== SRV-DNS
if [[ $ROLE == dns ]]; then
  log "Hostname und Netz (SRV-DNS, 10.10.30.53/24)"
  hostnamectl set-hostname SRV-DNS
  if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1 SRV-DNS/" /etc/hosts
  else echo "127.0.1.1 SRV-DNS" >> /etc/hosts; fi
  rm -f /etc/netplan/*.yaml
  cat > /etc/netplan/01-dhcp.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      dhcp4: false
      addresses: [10.10.30.53/24]
      routes: [{to: default, via: 10.10.30.1}]
      nameservers: {addresses: [1.1.1.1, 8.8.8.8]}
EOF
  chmod 600 /etc/netplan/01-dhcp.yaml
  netplan apply
  sleep 5

  log "Automatische Updates deaktivieren"
  systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

  log "BIND 9 und bind_exporter"
  $APT update
  $APT install bind9 bind9-utils bind9-dnsutils prometheus-bind-exporter curl
  wireshark_install
  mkdir -p /etc/bind/zones
  chown root:bind /etc/bind/zones
  chmod 2775 /etc/bind/zones
  systemctl enable --now named
  systemctl enable --now prometheus-bind-exporter
  named-checkconf && echo "BIND-Standardkonfiguration gültig"
fi

# ====================================================================== SRV-WEB
if [[ $ROLE == web ]]; then
  log "dnsperf, Wireshark, tshark"
  $APT update
  $APT install dnsperf bind9-dnsutils
  wireshark_install

  log "Anfragemix für dnsperf"
  mkdir -p /opt/lab/dns
  wget -q "$KIT_URL/l16-anfragen.txt" -O /opt/lab/dns/anfragen.txt
  chmod 644 /opt/lab/dns/anfragen.txt
  echo "Zeilen im Anfragemix: $(wc -l < /opt/lab/dns/anfragen.txt)"

  log "Shop-Stack starten (läuft in diesem Lab im Hintergrund)"
  cd /opt/shop && docker compose up -d --wait || docker compose up -d
  cd /
fi

# ====================================================================== SRV-MON
if [[ $ROLE == mon ]]; then
  log "LibreOffice Calc (für den Monatsbericht)"
  $APT update
  $APT install --no-install-recommends libreoffice-calc libreoffice-gtk3

  log "Berichtsvorlage"
  mkdir -p /home/$U/lab
  wget -q "$KIT_URL/l16-bericht_oktober.xlsx" -O /home/$U/lab/bericht_oktober.xlsx
  chown -R $U:$U /home/$U/lab

  log "Prometheus: Job bind (SRV-DNS)"
  if ! grep -q 'job_name: bind' /etc/prometheus/prometheus.yml; then
    python3 - <<'PYEOF'
p = "/etc/prometheus/prometheus.yml"
s = open(p).read()
job = """
  - job_name: bind
    static_configs:
      - targets: ['10.10.30.53:9119']
"""
if "\nrule_files:" in s:
    i = s.index("\nrule_files:")
    s = s[:i].rstrip("\n") + "\n" + job + s[i:]
else:
    s = s.rstrip("\n") + "\n" + job
open(p, "w").write(s)
PYEOF
    echo "Job bind ergänzt"
  else
    echo "Job bind vorhanden"
  fi
  docker exec prometheus promtool check config /config/prometheus.yml
  curl -sf -X POST http://localhost:9090/-/reload && echo "Prometheus neu geladen"

  log "Grafana: Dashboard DNS-Dienst"
  G="http://localhost:3000"; GA="admin:Gns3456"
  PUID=$(curl -sf -u $GA $G/api/datasources/name/prometheus | python3 -c 'import json,sys; print(json.load(sys.stdin)["uid"])')
  PUID=$PUID python3 > /tmp/l16-dashboard.json <<'PYEOF'
import json, os
P = {"type": "prometheus", "uid": os.environ["PUID"]}
def stat(pid, title, expr, x, desc):
    return {"id": pid, "type": "stat", "title": title, "description": desc, "datasource": P,
            "gridPos": {"x": x, "y": 0, "w": 6, "h": 5},
            "targets": [{"refId": "A", "datasource": P, "expr": expr, "instant": True}],
            "options": {"colorMode": "background", "reduceOptions": {"calcs": ["lastNotNull"]}},
            "fieldConfig": {"defaults": {"noValue": "keine Daten",
                            "mappings": [{"type": "value", "options": {"0": {"text": "NEIN"}, "1": {"text": "JA"}}}],
                            "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}},
                            "overrides": []}}
def total(pid, title, expr, legend, x, w, desc):
    # Summe über den oben rechts gewählten Zeitraum ($__range); increase() erkennt Zähler-Resets
    return {"id": pid, "type": "stat", "title": title, "description": desc, "datasource": P,
            "gridPos": {"x": x, "y": 16, "w": w, "h": 6},
            "targets": [{"refId": "A", "datasource": P, "expr": expr, "legendFormat": legend, "instant": True}],
            "options": {"colorMode": "none", "graphMode": "none", "textMode": "value_and_name",
                        "reduceOptions": {"calcs": ["lastNotNull"]}},
            "fieldConfig": {"defaults": {"noValue": "keine Daten", "decimals": 0, "unit": "short"}, "overrides": []}}
def ts(pid, title, targets, x, y, w, unit, desc):
    return {"id": pid, "type": "timeseries", "title": title, "description": desc, "datasource": P,
            "gridPos": {"x": x, "y": y, "w": w, "h": 8},
            "targets": [{"refId": chr(65 + i), "datasource": P, "expr": e, "legendFormat": l} for i, (e, l) in enumerate(targets)],
            "fieldConfig": {"defaults": {"unit": unit, "min": 0}, "overrides": []}}
panels = [
  stat(1, "Exporter erreichbar (up)", 'up{job="bind"}', 0, "Prometheus erreicht den bind_exporter auf SRV-DNS."),
  stat(2, "BIND liefert Werte (bind_up)", 'bind_up', 6, "Der bind_exporter erreicht den Statistik-Kanal von BIND."),
  ts(3, "Anfragen pro Sekunde", [('sum(rate(bind_incoming_queries_total[1m]))', "Anfragen/s")], 12, 0, 12, "reqps",
     "Rate über 1 Minute. Raten überstehen einen Neustart von BIND (Zähler-Reset)."),
  ts(4, "Antworten pro Sekunde nach RCODE",
     [('sum by (rcode) (rate(bind_response_rcodes_total{rcode=~"NOERROR|NXDOMAIN|SERVFAIL|REFUSED"}[1m]))', "{{rcode}}")], 0, 8, 12, "reqps",
     "Antwortcode im Header jeder Antwort. NOERROR enthält auch Antworten ohne Eintrag (NODATA)."),
  ts(5, "Rohzähler Antworten nach RCODE seit Start von BIND",
     [('sum by (rcode) (bind_response_rcodes_total{rcode=~"NOERROR|NXDOMAIN|SERVFAIL|REFUSED"})', "{{rcode}}")], 12, 8, 12, "short",
     "Kumulierte Zähler. Fallen nach einem Neustart von BIND auf 0."),
  total(7, "Anfragen gesamt (Zeitraum)", 'sum(increase(bind_incoming_queries_total[$__range]))', "Anfragen", 0, 4,
     "Anfragen im oben rechts gewählten Zeitraum. Zeitraum auf das Lastfenster setzen."),
  total(8, "Antworten je RCODE (Zeitraum)",
     'sum by (rcode) (increase(bind_response_rcodes_total{rcode=~"NOERROR|NXDOMAIN|SERVFAIL"}[$__range]))', "{{rcode}}", 4, 8,
     "Antworten je RCODE im oben rechts gewählten Zeitraum. increase() rechnet über einen Neustart von BIND hinweg."),
  ts(6, "Upstream: Rundlaufzeit der Anfragen an die Forwarder (p95)",
     [('histogram_quantile(0.95, sum by (le) (rate(bind_resolver_query_duration_seconds_bucket{view="_default"}[1m])))', "p95 Upstream")], 12, 16, 12, "s",
     "Zeit, bis die Forwarder BIND antworten. Das ist NICHT die Antwortzeit, die ein Client erlebt."),
]
dash = {"uid": "dns-dienst", "title": "DNS-Dienst", "tags": ["techtrade", "l16"],
        "timezone": "browser", "refresh": "10s", "schemaVersion": 39,
        "time": {"from": "now-30m", "to": "now"}, "panels": panels}
print(json.dumps({"dashboard": dash, "overwrite": True}))
PYEOF
  curl -sf -u $GA -H 'Content-Type: application/json' -X POST $G/api/dashboards/db \
    -d @/tmp/l16-dashboard.json >/dev/null && echo "Dashboard DNS-Dienst angelegt"
  rm -f /tmp/l16-dashboard.json

  log "Mailpit: Posteingang leeren"
  curl -sf -X DELETE http://localhost:8025/api/v1/messages >/dev/null && echo "Posteingang leer" || echo "WARNUNG: Mailpit nicht erreichbar"
fi

log "Cheatsheet und Prüfskript"
mkdir -p /home/$U/Desktop && chown $U:$U /home/$U/Desktop
rm -f /home/$U/lab-cheatsheet.txt                      # alter Ablageort (vor 01.11.)
if wget -q "$KIT_URL/l16-cheatsheet.txt" -O /home/$U/Desktop/lab-cheatsheet.txt; then
  echo "Cheatsheet L16 geladen"
else
  echo "HINWEIS: l16-cheatsheet.txt noch nicht im Repo - vor dem Einfrieren nachladen"
fi
chown $U:$U /home/$U/Desktop/lab-cheatsheet.txt 2>/dev/null || true
mkdir -p /home/$U/lab && chown $U:$U /home/$U/lab
wget -q "$KIT_URL/l16-verify.sh" -O /home/$U/lab/l16-verify.sh 2>/dev/null && chown $U:$U /home/$U/lab/l16-verify.sh || true

log "FERTIG L16 ($ROLE)"
echo "Prüfen:  bash ~/lab/l16-verify.sh"
[[ $ROLE != mon ]] && echo "Neu anmelden oder neu starten, damit gns3 ohne sudo Pakete aufzeichnen darf."
exit 0
