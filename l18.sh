#!/usr/bin/env bash
# PLAN-200 L18 Lab-Kit (Kapazitäten prognostizieren und Plattformen skalieren)
# Baut auf dem eingefrorenen L17-Template auf (Duplikat, KALI ersetzt durch KUNDE an R1 eth3).
# Aufruf:  sudo bash l18.sh web     (auf SRV-WEB, zuerst)
#          sudo bash l18.sh mon     (auf SRV-MON)
#          sudo bash l18.sh kunde   (auf KUNDE, 203.0.113.66 im «Internet»)
# Optional: sudo RENDER_MS=16 bash l18.sh web   (Rechenzeit pro Seitenaufruf in CPU-ms, Standard 14)
set -euo pipefail

KIT_URL="${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main}"
ROLE="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten."; exit 1; }
case "$ROLE" in mon|web|kunde) ;; *) echo "Aufruf: sudo bash l18.sh web|mon|kunde"; exit 1 ;; esac

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -q -o DPkg::Lock::Timeout=300"
U=gns3
H=/home/$U
RENDER_MS="${RENDER_MS:-14}"
CADVISOR=ghcr.io/google/cadvisor:0.60.5
K6=grafana/k6:1.3.0
WEB=10.10.20.13
log(){ echo; echo "=== $* ==="; }

cheatsheet(){
  mkdir -p $H/Desktop
  wget -q "$KIT_URL/l18-cheatsheet.txt" -O $H/Desktop/lab-cheatsheet.txt
  chown -R $U:$U $H/Desktop
  echo "Cheatsheet: $H/Desktop/lab-cheatsheet.txt"
}

iperf_install(){
  echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
  $APT install iperf3 >/dev/null
  systemctl disable --now iperf3 iperf3-lab 2>/dev/null || true   # kein Dienst: Studierende starten iperf3 -s selbst
  echo "iperf3: $(iperf3 --version | head -1)"
}

# ====================================================================== SRV-WEB
if [[ $ROLE == web ]]; then
  log "Suricata stoppen (braucht CPU, wird in diesem Lab nicht verwendet)"
  systemctl disable --now suricata 2>/dev/null || true

  log "iperf3"
  $APT update >/dev/null
  iperf_install

  log "Shop-Image 2.0 bauen (Rechenzeit pro Seitenaufruf: $RENDER_MS CPU-ms)"
  B=/opt/lab/shop-app-2
  mkdir -p $B
  wget -q "$KIT_URL/l18-app.py" -O $B/app.py
  cat > $B/Dockerfile <<'DFEOF'
# TechTrade Shop 2.0 - Lab-Anwendung PLAN-200 Lektion 18
FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary==2.9.10 \
 && apt-get update && apt-get install -y --no-install-recommends tzdata \
 && (apt-get install -y --no-install-recommends tzdata-legacy || true) \
 && rm -rf /var/lib/apt/lists/* \
 && test -e /usr/share/zoneinfo/Europe/Zurich
WORKDIR /app
COPY app.py .
ARG RENDER_MS=14
ENV SHOP_VERSION=2.0 RENDER_MS=${RENDER_MS} PYTHONUNBUFFERED=1 TZ=Europe/Zurich
RUN useradd --system --no-create-home shop
USER shop
EXPOSE 8080
CMD ["python", "app.py"]
DFEOF
  docker build -q --build-arg RENDER_MS=$RENDER_MS -t techtrade/shop:2.0 $B

  log "Images vorladen"
  for i in nginx:1.30.5-alpine postgres:16.15-alpine; do docker pull -q $i; done
  docker image inspect $CADVISOR >/dev/null 2>&1 || {
    docker pull -q ghcr.io/google/cadvisor:v0.60.5
    docker tag ghcr.io/google/cadvisor:v0.60.5 $CADVISOR
    docker rmi ghcr.io/google/cadvisor:v0.60.5 >/dev/null; }

  log "Alten Shop-Stack entfernen (inkl. Daten)"
  if [[ -f /opt/shop/compose.yaml ]]; then
    (cd /opt/shop && docker compose down -v --remove-orphans) || true
  fi

  log "Shop-Stack 2.0 in /opt/shop anlegen"
  S=/opt/shop
  rm -rf $S/nginx $S/.env
  mkdir -p $S/nginx $S/secrets
  cat > $S/compose.yaml <<'CEOF'
# TechTrade Shop - Container-Stack auf SRV-WEB
# Prüfen:    sudo docker compose config
# Starten:   sudo docker compose up -d
# Status:    sudo docker compose ps
name: shop

services:
  proxy:
    image: nginx:1.30.5-alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/ssl/techtrade:/etc/ssl/techtrade:ro
      - /etc/localtime:/etc/localtime:ro      # Zeitzone des Hosts für die Log-Zeitstempel
    depends_on:
      - app1
      - app2
    restart: unless-stopped
    networks: [frontend]

  app1:
    image: techtrade/shop:2.0
    environment:
      APP_NAME: app1                          # Name der Instanz, erscheint im Header X-Backend
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: shop
      DB_NAME: shop
      DB_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    depends_on:
      - db
    deploy:
      resources:
        limits:
          cpus: "0.25"                        # höchstens ein Viertel einer CPU
          memory: 256M
    restart: unless-stopped
    networks: [frontend, backend]

  app2:
    image: techtrade/shop:2.0
    environment:
      APP_NAME: app2
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: shop
      DB_NAME: shop
      DB_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    depends_on:
      - db
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 256M
    restart: unless-stopped
    networks: [frontend, backend]

  db:
    image: postgres:16.15-alpine
    environment:
      POSTGRES_USER: shop
      POSTGRES_DB: shop
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      TZ: Europe/Zurich
    secrets: [db_password]
    volumes:
      - dbdata:/var/lib/postgresql/data
    restart: unless-stopped
    networks: [backend]

networks:
  frontend:
  backend:
    internal: true

volumes:
  dbdata:

secrets:
  db_password:
    file: ./secrets/db_password.txt
CEOF
  printf 'TechTrade-DB1\n' > $S/secrets/db_password.txt
  cat > $S/nginx/default.conf <<'NEOF'
# Reverse Proxy des TechTrade Shops (Container proxy)
# Prüfen:     sudo docker compose exec proxy nginx -t
# Neu laden:  sudo docker compose exec proxy nginx -s reload

# Applikationsserver des Shops (Lastverteilung: Round Robin)
upstream shop_app {
    server app1:8080;
    server app2:8080;
}

server {
    listen 80;
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/ssl/techtrade/shop.crt;
    ssl_certificate_key /etc/ssl/techtrade/shop.key;

    location / {
        proxy_pass http://shop_app;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 3s;
        proxy_read_timeout    10s;
    }
}
NEOF
  chmod 755 $S $S/nginx $S/secrets
  chmod 644 $S/compose.yaml $S/nginx/default.conf $S/secrets/db_password.txt

  log "cAdvisor: misst CPU und Arbeitsspeicher pro Container (Port 8081)"
  mkdir -p /opt/cadvisor
  cat > /opt/cadvisor/compose.yaml <<'CAEOF'
# cAdvisor - misst CPU, Arbeitsspeicher, Netz und Disk pro Container (SRV-WEB)
services:
  cadvisor:
    image: ghcr.io/google/cadvisor:0.60.5
    ports:
      - "8081:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /run/containerd:/run/containerd:ro    # Docker 29: Containernamen über containerd
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    devices:
      - /dev/kmsg
    privileged: true
    restart: unless-stopped
CAEOF
  chmod 644 /opt/cadvisor/compose.yaml
  docker compose -f /opt/cadvisor/compose.yaml up -d

  log "Shop-Stack starten und prüfen"
  cd $S
  docker compose config -q
  docker compose up -d
  OK=0
  for i in $(seq 1 60); do
    if curl -sk https://localhost/ | grep -q "TechTrade Shop"; then OK=1; break; fi
    sleep 2
  done
  [[ $OK == 1 ]] || { echo "FEHLER: Shop antwortet nicht"; exit 1; }
  for i in 1 2 3 4; do curl -sk -D - -o /dev/null https://localhost/ | grep -i x-backend; done
  docker compose logs app1 | grep startet || true
  cd /

  mkdir -p $H/lab
  wget -q "$KIT_URL/l18-verify.sh" -O $H/lab/l18-verify.sh
  chown -R $U:$U $H/lab
  cheatsheet
fi

# ====================================================================== SRV-MON
if [[ $ROLE == mon ]]; then
  log "iperf3 und LibreOffice Calc"
  $APT update >/dev/null
  iperf_install
  $APT install --no-install-recommends libreoffice-calc libreoffice-gtk3 >/dev/null
  echo "LibreOffice: $(dpkg-query -W -f='${Version}' libreoffice-calc)"
  # Erststart-Hinweis ("running version ... for the first time") unterdrücken
  LOV=$(dpkg-query -W -f='${Version}' libreoffice-calc | sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+).*/\1/')
  sudo -u $U timeout 60 soffice --headless --terminate_after_init >/dev/null 2>&1 || true
  REG=$H/.config/libreoffice/4/user/registrymodifications.xcu
  if [[ -f $REG ]] && ! grep -q ooSetupLastVersion $REG; then
    sed -i "s#</oor:items>#<item oor:path=\"/org.openoffice.Setup/Product\"><prop oor:name=\"ooSetupLastVersion\" oor:op=\"fuse\"><value>$LOV</value></prop></item>\n</oor:items>#" $REG
  fi
  echo "LibreOffice-Profil angelegt (Version $LOV)"

  log "Lastgenerator läuft auf KUNDE: alte k6-Dateien auf SRV-MON entfernen"
  rm -rf $H/lab/k6
  docker rmi $K6 >/dev/null 2>&1 || true
  mkdir -p $H/lab
  wget -q "$KIT_URL/l18-kapazitaet.xlsx" -O $H/lab/kapazitaet.xlsx
  chown -R $U:$U $H/lab

  log "Prometheus: Job cadvisor (SRV-WEB:8081)"
  if ! grep -q 'job_name: cadvisor' /etc/prometheus/prometheus.yml; then
    python3 - <<'PYEOF'
p = "/etc/prometheus/prometheus.yml"
s = open(p).read()
job = """
  - job_name: cadvisor
    static_configs:
      - targets: ['10.10.20.13:8081']
"""
if "\nrule_files:" in s:
    i = s.index("\nrule_files:")
    s = s[:i].rstrip("\n") + "\n" + job + s[i:]
else:
    s = s.rstrip("\n") + "\n" + job
open(p, "w").write(s)
PYEOF
    echo "Job cadvisor ergänzt"
  else
    echo "Job cadvisor vorhanden"
  fi

  log "Alarm: Upload des Internetanschlusses (R1 eth3, 50 Mbit/s)"
  if [[ -f /etc/prometheus/alerts.yml ]]; then
    sed -i -E 's#rate\(ifHCOutOctets\{job="snmp", ifName="eth[0-9]"\}\[1m\]\) \* 8 / [0-9]+e6 \* 100 > 80#rate(ifHCOutOctets{job="snmp", ifName="eth3"}[1m]) * 8 / 50e6 * 100 > 80#' /etc/prometheus/alerts.yml
    sed -i -E 's#summary: "(R1 eth2 zum Server-Segment|WAN-Leitung Rechenzentrum \(R1 eth2\)) zu#summary: "Upload Internetanschluss (R1 eth3) zu#' /etc/prometheus/alerts.yml
    sed -i -E 's#Über 80 % der (geplanten 100|vertraglichen 50) Mbit/s seit über 2 Minuten\.#Über 80 % der vertraglichen 50 Mbit/s Upload seit über 2 Minuten.#' /etc/prometheus/alerts.yml
    grep -n 'ifName="eth3"' /etc/prometheus/alerts.yml || echo "WARNUNG: Alarmregel Upload nicht gefunden"
  fi
  docker exec prometheus promtool check config /config/prometheus.yml
  curl -sf -X POST http://localhost:9090/-/reload && echo "Prometheus neu geladen"

  log "Grafana: Dashboard Kapazität Shop"
  G="http://localhost:3000"; GA="admin:Gns3456"
  PUID=$(curl -sf -u $GA $G/api/datasources/name/prometheus | python3 -c 'import json,sys; print(json.load(sys.stdin)["uid"])')
  PUID=$PUID python3 > /tmp/l18-dashboard.json <<'PYEOF'
import json, os
P = {"type": "prometheus", "uid": os.environ["PUID"]}
def ts(pid, title, targets, x, y, w, unit, desc, overrides=None, mn=0, mx=None, extra=None):
    d = {"unit": unit, "min": mn, "custom": {"lineWidth": 2}}
    if mx is not None:
        d["max"] = mx
    if extra:
        d.update(extra)
        d["custom"]["thresholdsStyle"] = {"mode": "dashed"}
    return {"id": pid, "type": "timeseries", "title": title, "description": desc, "datasource": P,
            "gridPos": {"x": x, "y": y, "w": w, "h": 9},
            "targets": [dict(refId=chr(65 + i), datasource=P, **t) for i, t in enumerate(targets)],
            "fieldConfig": {"defaults": d, "overrides": overrides or []}}
dash_limit = [{"matcher": {"id": "byRegexp", "options": "Limit.*"},
               "properties": [{"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}},
                              {"id": "custom.lineWidth", "value": 1}]}]
lim100 = {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 100}]}}
APPCPU = 'sum by (name) (rate(container_cpu_usage_seconds_total{name=~"shop-app.*"}[1m])) / max by (name) (container_spec_cpu_quota{name=~"shop-app.*"} / container_spec_cpu_period{name=~"shop-app.*"}) * 100'
THROT = 'sum by (name) (rate(container_cpu_cfs_throttled_periods_total{name=~"shop-app.*"}[1m])) / sum by (name) (rate(container_cpu_cfs_periods_total{name=~"shop-app.*"}[1m])) * 100'
panels = [
  ts(1, "Internetanschluss (R1 eth3)", [
       {"expr": 'rate(ifHCOutOctets{job="snmp", ifName="eth3"}[1m]) * 8 / 1e6', "legendFormat": "Upload (zum Internet)"},
       {"expr": 'rate(ifHCInOctets{job="snmp", ifName="eth3"}[1m]) * 8 / 1e6', "legendFormat": "Download (aus dem Internet)"}],
     0, 0, 12, "Mbit/s", "Durchsatz des Internetanschlusses in beide Richtungen, Mittel über 1 Minute (SNMP von R1)."),
  ts(2, "CPU Applikationsserver (% ihres Limits)", [
       {"expr": APPCPU, "legendFormat": "{{name}}"}],
     12, 0, 12, "percent", "CPU-Verbrauch jedes Applikationsservers im Verhältnis zu seinem CPU-Limit. 100 % (rote Linie) = Limit erreicht. Mittel über 1 Minute, darum unter Volllast meist etwas unter 100 %.", None, 0, 110, lim100),
  ts(3, "CPU-Drosselung Applikationsserver (%)", [
       {"expr": THROT, "legendFormat": "{{name}}"}],
     0, 9, 12, "percent", "Anteil der Zeitscheiben (je 100 ms), in denen der Kernel den Container bremsen musste, weil er sein CPU-Limit aufgebraucht hatte. Hoch = der Container will mehr CPU, als er darf.", None, 0, 100),
  ts(4, "CPU Reverse Proxy und Datenbank (% einer CPU)", [
       {"expr": 'sum by (name) (rate(container_cpu_usage_seconds_total{name=~"shop-(proxy|db).*"}[1m])) * 100', "legendFormat": "{{name}}"}],
     12, 9, 12, "percent", "CPU-Verbrauch von Reverse Proxy und Datenbank in Prozent einer ganzen CPU (diese Container haben kein Limit)."),
  ts(5, "Stichprobe: Antwortzeit des Shops", [
       {"expr": 'probe_duration_seconds{job="shop"}', "legendFormat": "Antwortzeit"}],
     0, 18, 12, "s", "Stichprobe: blackbox_exporter auf SRV-MON ruft den Shop alle paar Sekunden einmal auf. Zeigt die Zeit bis zu irgendeiner Antwort, auch bis zu einer Fehlermeldung. Immer zusammen mit dem Panel Erreichbarkeit lesen. Jede einzelne Anfrage misst nur k6."),
  ts(6, "Stichprobe: Shop erreichbar (1 = ja, 0 = Fehler)", [
       {"expr": 'probe_success{job="shop"}', "legendFormat": "erreichbar"}],
     12, 18, 12, "none", "1 = die Stichprobe hat eine fehlerfreie Antwort erhalten (Status 200). 0 = Fehler oder keine Antwort.", None, 0, 1),
  ts(7, "Arbeitsspeicher pro Shop-Container", [
       {"expr": 'max by (name) (container_memory_working_set_bytes{name=~"shop-.*"})', "legendFormat": "{{name}}"}],
     0, 27, 12, "bytes", "Arbeitsspeicher pro Container (cAdvisor)."),
]
dash = {"uid": "kapazitaet-shop", "title": "Kapazität Shop", "tags": ["techtrade", "l18"],
        "timezone": "browser", "refresh": "10s", "schemaVersion": 39,
        "time": {"from": "now-15m", "to": "now"}, "panels": panels}
print(json.dumps({"dashboard": dash, "overwrite": True}))
PYEOF
  curl -sf -u $GA -H 'Content-Type: application/json' -X POST $G/api/dashboards/db \
    -d @/tmp/l18-dashboard.json >/dev/null && echo "Dashboard Kapazität Shop angelegt"
  rm -f /tmp/l18-dashboard.json

  wget -q "$KIT_URL/l18-verify.sh" -O $H/lab/l18-verify.sh
  chown -R $U:$U $H/lab
  cheatsheet
fi

# ====================================================================== KUNDE
if [[ $ROLE == kunde ]]; then
  log "Hostname und Netz (KUNDE, 203.0.113.66/24 im «Internet»)"
  hostnamectl set-hostname KUNDE
  if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1 KUNDE/" /etc/hosts
  else echo "127.0.1.1 KUNDE" >> /etc/hosts; fi
  rm -f /etc/netplan/*.yaml
  cat > /etc/netplan/01-dhcp.yaml <<'NPEOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      dhcp4: false
      addresses: [203.0.113.66/24]
      routes: [{to: default, via: 203.0.113.1}]
      nameservers: {addresses: [1.1.1.1, 8.8.8.8]}
NPEOF
  chmod 600 /etc/netplan/01-dhcp.yaml
  netplan apply
  sleep 5
  systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

  log "iperf3, curl, Docker"
  $APT update >/dev/null
  iperf_install
  $APT install curl docker.io >/dev/null
  systemctl enable --now docker

  log "k6 (Lastgenerator, als Container)"
  if ! docker pull -q $K6; then
    docker pull -q grafana/k6:latest
    docker tag grafana/k6:latest $K6
  fi
  docker run --rm $K6 version

  log "Lasttest ~/lab/k6/weihnachten.js"
  mkdir -p $H/lab/k6
  cat > $H/lab/k6/weihnachten.js <<'K6EOF'
// Lasttest Weihnachtsaktion - TechTrade Shop, aufgerufen wie von Kunden aus dem Internet
// Starten auf KUNDE im Ordner ~/lab/k6:
//   sudo docker run --rm -i grafana/k6:1.3.0 run - < weihnachten.js
import http from 'k6/http';

// Ziellast in Anfragen pro Sekunde (aus der Analyse der Geschäftsplanung)
const ANFRAGEN_PRO_SEKUNDE = 1;

export const options = {
  insecureSkipTLSVerify: true,            // Shop hat ein selbstsigniertes Zertifikat
  scenarios: {
    weihnachten: {
      executor: 'constant-arrival-rate',  // feste Anzahl Anfragen pro Sekunde, egal wie schnell der Shop antwortet
      rate: ANFRAGEN_PRO_SEKUNDE,
      timeUnit: '1s',
      duration: '2m',
      preAllocatedVUs: 50,                // virtuelle Benutzer, die k6 zu Beginn bereithält
      maxVUs: 400,                        // höchstens so viele gleichzeitig wartende Anfragen
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500'],     // Ziel: 95 % der Anfragen dauern höchstens 500 ms
    http_req_failed: ['rate<0.01'],       // Ziel: weniger als 1 % Fehler
  },
};

export default function () {
  // Mischung wie im echten Betrieb: zwei Drittel Shop-Seite (dynamisch), ein Drittel Stylesheet (statisch)
  if (Math.random() < 1 / 3) {
    http.get('https://203.0.113.1/static/shop.css');
  } else {
    http.get('https://203.0.113.1/');
  }
}
K6EOF

  log "Shop über die öffentliche Adresse"
  curl -sk -o /dev/null -w "https://203.0.113.1 -> HTTP %{http_code}\n" https://203.0.113.1/ \
    || echo "WARNUNG: Shop über 203.0.113.1 nicht erreichbar (DNAT auf R1?)"

  wget -q "$KIT_URL/l18-verify.sh" -O $H/lab/l18-verify.sh
  chown -R $U:$U $H/lab
  cheatsheet
fi

echo; echo "=== fertig: $ROLE. Danach: bash ~/lab/l18-verify.sh ==="
