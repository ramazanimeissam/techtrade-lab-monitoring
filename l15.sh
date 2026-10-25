#!/usr/bin/env bash
# PLAN-200 L15 Lab-Kit (Container-Plattform: Docker, Docker Compose, Vorfälle)
# Baut auf dem eingefrorenen L14-Template auf (Duplikat).
# Aufruf:  sudo bash l15.sh web   (auf SRV-WEB, zuerst)
#          sudo bash l15.sh mon   (auf SRV-MON)
set -euo pipefail

KIT_URL="${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main}"
ROLE="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten."; exit 1; }
case "$ROLE" in mon|web) ;; *) echo "Aufruf: sudo bash l15.sh web|mon"; exit 1 ;; esac

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=300"
U=gns3
CADVISOR=ghcr.io/google/cadvisor:0.60.5
log(){ echo; echo "=== $* ==="; }

# ====================================================================== SRV-WEB
if [[ $ROLE == web ]]; then
  log "Docker Engine und Compose installieren"
  $APT update
  $APT install docker.io docker-compose-v2
  systemctl enable --now docker
  rm -f /etc/docker/daemon.json          # Ausgangszustand: keine Log-Rotation

  log "nginx auf dem Host stilllegen (Shop läuft neu im Container)"
  systemctl disable --now nginx 2>/dev/null || true

  log "Shop-Images 1.4, 1.5 und 1.6 bauen"
  B=/opt/lab/shop-app
  mkdir -p $B
  cat > $B/app.py <<'APPEOF'
"""TechTrade Shop - kleine Lab-Anwendung (PLAN-200 Lektion 15).

Version 1.4: normaler Betrieb.
Version 1.5: Speicherleck - jede Anfrage belegt Arbeitsspeicher, der nie freigegeben wird.
Version 1.6: hängt nach etwa 90 Sekunden - der Prozess lebt, beantwortet aber keine Anfragen mehr.
"""
import html
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

import psycopg2

VERSION = os.environ.get("SHOP_VERSION", "1.4")
PORT = int(os.environ.get("APP_PORT", "8080"))
DB = {
    "host": os.environ.get("DB_HOST", "db"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "user": os.environ.get("DB_USER", "shop"),
    "dbname": os.environ.get("DB_NAME", "shop"),
    "connect_timeout": 3,
    "options": "-c timezone=Europe/Zurich",
}
_pw_file = os.environ.get("DB_PASSWORD_FILE")
if _pw_file:
    with open(_pw_file, encoding="utf-8") as f:
        DB["password"] = f.read().strip()
else:
    DB["password"] = os.environ.get("DB_PASSWORD", "")

START = time.time()
LEAK = []                 # nur Version 1.5
HANG_AFTER = int(os.environ.get("HANG_AFTER", "90"))          # nur Version 1.6, Sekunden nach dem Start
PRODUCTS = [
    ("NB-14", "Notebook 14 Zoll", 899),
    ("MON-27", "Monitor 27 Zoll", 329),
    ("DOCK-1", "USB-C-Dock", 149),
]
_schema_ok = False


def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} shop[{VERSION}] {msg}", flush=True)


def db():
    global _schema_ok
    conn = psycopg2.connect(**DB)
    if not _schema_ok:
        with conn, conn.cursor() as cur:
            cur.execute(
                "CREATE TABLE IF NOT EXISTS bestellungen ("
                " id SERIAL PRIMARY KEY, artikel TEXT NOT NULL, menge INT NOT NULL,"
                " zeit TIMESTAMPTZ NOT NULL DEFAULT now())"
            )
            cur.execute("SELECT count(*) FROM bestellungen")
            if cur.fetchone()[0] == 0:
                cur.executemany(
                    "INSERT INTO bestellungen (artikel, menge) VALUES (%s, %s)",
                    [("NB-14", 2), ("MON-27", 5), ("DOCK-1", 3)],
                )
        _schema_ok = True
    return conn


class Shop(BaseHTTPRequestHandler):
    server_version = "TechTradeShop/" + VERSION
    sys_version = ""

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} \"{self.requestline}\" {args[1] if len(args) > 1 else ''}")

    def _before(self):
        if VERSION == "1.5":
            LEAK.append(b"\x01" * (8 * 1024 * 1024))
            log(f"Warenkorb-Cache: {len(LEAK)} Einträge")
        if VERSION == "1.6" and time.time() - START > HANG_AFTER:
            time.sleep(3600)

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._before()
        if self.path == "/health":
            try:
                with db() as conn, conn.cursor() as cur:
                    cur.execute("SELECT 1")
                self._send(200, "ok\n", "text/plain; charset=utf-8")
            except Exception as e:
                log(f"FEHLER Healthcheck: Datenbank {DB['host']}:{DB['port']} nicht erreichbar: {e}".strip())
                self._send(503, "Datenbank nicht erreichbar\n", "text/plain; charset=utf-8")
            return
        if self.path not in ("/", "/index.html"):
            self._send(404, "<h1>404 - Seite nicht gefunden</h1>")
            return
        try:
            with db() as conn, conn.cursor() as cur:
                cur.execute("SELECT artikel, menge, zeit FROM bestellungen ORDER BY id DESC LIMIT 5")
                rows = cur.fetchall()
                cur.execute("SELECT count(*) FROM bestellungen")
                total = cur.fetchone()[0]
        except Exception as e:
            log(f"FEHLER: Datenbank {DB['host']}:{DB['port']} nicht erreichbar: {e}".strip())
            self._send(500, "<h1>500 - Interner Fehler</h1><p>Bestellungen können nicht geladen werden.</p>")
            return
        prod = "".join(
            f"<tr><td>{a}</td><td>{html.escape(n)}</td><td>CHF {p}</td>"
            f"<td><form method='post' action='/bestellen'><input type='hidden' name='artikel' value='{a}'>"
            f"<input name='menge' value='1' size='2'> <button>Bestellen</button></form></td></tr>"
            for a, n, p in PRODUCTS
        )
        last = "".join(f"<li>{z:%d.%m.%Y %H:%M:%S} - {m} x {html.escape(a)}</li>" for a, m, z in rows)
        page = (
            "<!doctype html><html lang='de'><head><meta charset='utf-8'><title>TechTrade Shop</title></head>"
            "<body style='font-family:Arial,sans-serif;max-width:720px;margin:2em auto'>"
            f"<h1>TechTrade Shop</h1><p>Version {VERSION}</p>"
            f"<table border='1' cellpadding='6' style='border-collapse:collapse'>"
            f"<tr><th>Artikel</th><th>Bezeichnung</th><th>Preis</th><th></th></tr>{prod}</table>"
            f"<h2>Bestellungen: {total}</h2><ul>{last}</ul></body></html>"
        )
        self._send(200, page)

    def do_POST(self):
        self._before()
        if self.path != "/bestellen":
            self._send(404, "<h1>404 - Seite nicht gefunden</h1>")
            return
        length = int(self.headers.get("Content-Length", "0"))
        form = parse_qs(self.rfile.read(length).decode("utf-8"))
        artikel = form.get("artikel", [""])[0]
        try:
            menge = int(form.get("menge", ["1"])[0])
        except ValueError:
            menge = 0
        if artikel not in {a for a, _, _ in PRODUCTS} or not 1 <= menge <= 99:
            self._send(400, "<h1>400 - Ungültige Bestellung</h1>")
            return
        try:
            with db() as conn, conn.cursor() as cur:
                cur.execute("INSERT INTO bestellungen (artikel, menge) VALUES (%s, %s)", (artikel, menge))
        except Exception as e:
            log(f"FEHLER: Bestellung nicht gespeichert: {e}".strip())
            self._send(500, "<h1>500 - Interner Fehler</h1><p>Bestellung nicht gespeichert.</p>")
            return
        log(f"Bestellung gespeichert: {menge} x {artikel}")
        self.send_response(303)
        self.send_header("Location", "/")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    log(f"TechTrade Shop {VERSION} startet auf Port {PORT}, Datenbank {DB['host']}:{DB['port']}")
    try:
        ThreadingHTTPServer(("0.0.0.0", PORT), Shop).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
APPEOF
  cat > $B/Dockerfile <<'DFEOF'
# TechTrade Shop - Lab-Anwendung PLAN-200 Lektion 15
FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary==2.9.10
WORKDIR /app
COPY app.py .
ARG SHOP_VERSION=1.4
ENV SHOP_VERSION=${SHOP_VERSION} PYTHONUNBUFFERED=1
RUN useradd --system --no-create-home shop
USER shop
EXPOSE 8080
CMD ["python", "app.py"]
DFEOF
  for v in 1.4 1.5 1.6; do
    docker build -q --build-arg SHOP_VERSION=$v -t techtrade/shop:$v $B
  done
  # python:3.12-slim bleibt als Image (Basis der Dockerfile-Übung)

  log "Images vorladen (langsame Internetanbindung im Lab)"
  for i in nginx:1.30.5-alpine nginx:1.30.6-alpine postgres:16.15-alpine; do
    docker pull -q $i
  done
  if ! docker pull -q $CADVISOR; then
    docker pull -q ghcr.io/google/cadvisor:v0.60.5
    docker tag ghcr.io/google/cadvisor:v0.60.5 $CADVISOR
    docker rmi ghcr.io/google/cadvisor:v0.60.5 >/dev/null
  fi

  log "Shop-Stack in /opt/shop anlegen"
  S=/opt/shop
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
    depends_on:
      - app
    restart: unless-stopped
    networks: [frontend]

  app:
    image: techtrade/shop:${SHOP_VERSION}
    environment:
      DB_HOST: ${DB_HOST}
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
  cat > $S/.env <<'ENVEOF'
# Version der Shop-Anwendung (Images: sudo docker images techtrade/shop)
SHOP_VERSION=1.4
# Datenbank-Server (Dienstname im Netz backend)
DB_HOST=db
ENVEOF
  printf 'TechTrade-DB1\n' > $S/secrets/db_password.txt
  cat > $S/nginx/default.conf <<'NEOF'
# Reverse Proxy des TechTrade Shops (Container proxy)
server {
    listen 80;
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/ssl/techtrade/shop.crt;
    ssl_certificate_key /etc/ssl/techtrade/shop.key;

    location / {
        proxy_pass http://app:8080;
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
  chmod 644 $S/compose.yaml $S/.env $S/nginx/default.conf $S/secrets/db_password.txt
  mkdir -p /backup && chmod 755 /backup

  log "Übung Dockerfile: /opt/lab/uebung (funktioniert, erfüllt die Vorgaben noch nicht)"
  E=/opt/lab/uebung
  mkdir -p $E
  cat > $E/Dockerfile <<'DEOF'
# Intranet-Startseite TechTrade AG
FROM python:latest
COPY index.html /srv/
WORKDIR /srv
CMD ["python", "-m", "http.server", "8000"]
DEOF
  cat > $E/index.html <<'HEOF'
<!doctype html>
<html lang="de">
<head><meta charset="utf-8"><title>Intranet</title></head>
<body style="font-family:Arial,sans-serif">
<h1>Intranet</h1>
<p>Platzhalter</p>
</body>
</html>
HEOF
  chmod 755 $E; chmod 644 $E/Dockerfile $E/index.html

  log "cAdvisor: /opt/cadvisor/compose.yaml (unvollständig, noch nicht gestartet)"
  mkdir -p /opt/cadvisor
  cat > /opt/cadvisor/compose.yaml <<'CAEOF'
# cAdvisor - misst CPU, Arbeitsspeicher, Netz und Disk pro Container (SRV-WEB)
services:
  cadvisor:
    image: ghcr.io/google/cadvisor:latest
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs
      - /var/run:/var/run
      - /sys:/sys
      - /var/lib/docker/:/var/lib/docker
      - /dev/disk/:/dev/disk
    devices:
      - /dev/kmsg
    privileged: true
CAEOF
  chmod 755 /opt/cadvisor; chmod 644 /opt/cadvisor/compose.yaml
  docker compose -f /opt/cadvisor/compose.yaml config -q

  log "Probelauf: Stack starten, Shop prüfen, alles wieder entfernen"
  cd $S
  docker compose config -q
  docker compose up -d
  OK=0
  for i in $(seq 1 60); do
    if curl -s http://localhost/ | grep -q "TechTrade Shop"; then OK=1; break; fi
    sleep 2
  done
  HTTPS=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/ || true)
  docker compose down -v
  cd /
  [[ $OK == 1 ]] || { echo "FEHLER: Shop antwortete im Probelauf nicht"; exit 1; }
  [[ $HTTPS == 200 ]] || { echo "FEHLER: HTTPS im Probelauf: $HTTPS"; exit 1; }
  echo "Probelauf ok (HTTP und HTTPS), Stack wieder entfernt"
fi

# ====================================================================== SRV-MON
if [[ $ROLE == mon ]]; then
  log "L14-Endzustand: Alarmregeln"
  cat > /etc/prometheus/alerts.yml <<'EOF'
groups:
  - name: techtrade
    rules:
      - alert: ZielNichtErreichbar
        expr: up == 0
        for: 1m
        labels:
          severity: kritisch
        annotations:
          summary: "{{ $labels.job }} auf {{ $labels.instance }} liefert keine Daten"
          description: "Seit über 1 Minute kein Messwert. Erste Massnahme: Dienst und Erreichbarkeit des Ziels prüfen."

      - alert: ShopNichtVerfuegbar
        expr: probe_success == 0
        for: 1m
        labels:
          severity: kritisch
        annotations:
          summary: "Shop {{ $labels.instance }} nicht verfügbar"
          description: "Prüfung schlägt seit über 1 Minute fehl (HTTP-Status oder Text falsch). Erste Massnahme: Shop-Stack auf SRV-WEB prüfen."

      - alert: ShopLangsam
        expr: probe_duration_seconds{job="shop"} > 0.1
        for: 1m
        labels:
          severity: hoch
        annotations:
          summary: "Shop antwortet langsam: {{ $value | humanizeDuration }}"
          description: "Antwortzeit seit über 1 Minute über 100 ms. Erste Massnahme: Auslastung Netz und SRV-WEB prüfen."

      - alert: AuslastungServerSegmentHoch
        expr: rate(ifHCOutOctets{job="snmp", ifName="eth2"}[1m]) * 8 / 100e6 * 100 > 80
        for: 2m
        labels:
          severity: warnung
        annotations:
          summary: "R1 eth2 zum Server-Segment zu {{ $value | printf \"%.0f\" }} % ausgelastet"
          description: "Über 80 % der geplanten 100 Mbit/s seit über 2 Minuten. Erste Massnahme: Verursacher im Dashboard suchen."
EOF
  chmod 644 /etc/prometheus/alerts.yml
  if ! grep -q '^rule_files:' /etc/prometheus/prometheus.yml; then
    printf '\nrule_files:\n  - /config/alerts.yml\n' >> /etc/prometheus/prometheus.yml
  fi

  log "L14-Endzustand: Alertmanager stellt per Mail zu"
  cat > /etc/alertmanager/alertmanager.yml <<'EOF'
# Alertmanager-Konfiguration TechTrade AG (SRV-MON)
# Bearbeiten:   sudo nano /etc/alertmanager/alertmanager.yml
# Prüfen:       sudo docker exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
# Neu laden:    curl -X POST http://localhost:9093/-/reload

# Mailserver: Mailpit auf SRV-MON (nimmt jede Mail an, ohne Anmeldung)
global:
  smtp_smarthost: 'localhost:1025'
  smtp_from: 'alertmanager@techtrade.lab'
  smtp_require_tls: false

# Alle Alarme an den Betrieb; gleichnamige Alarme in einer Mail bündeln
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
  chmod 644 /etc/alertmanager/alertmanager.yml

  log "Prüfen und neu laden"
  docker exec prometheus promtool check rules /config/alerts.yml
  docker exec prometheus promtool check config /config/prometheus.yml
  docker exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
  curl -sf -X POST http://localhost:9090/-/reload
  curl -sf -X POST http://localhost:9093/-/reload
  echo "Prometheus und Alertmanager neu geladen"
fi

log "Cheatsheet"
if wget -q "$KIT_URL/l15-cheatsheet.txt" -O /home/$U/lab-cheatsheet.txt; then
  echo "Cheatsheet L15 geladen"
else
  echo "HINWEIS: l15-cheatsheet.txt noch nicht im Repo - vor dem Einfrieren nachladen"
fi
chown $U:$U /home/$U/lab-cheatsheet.txt 2>/dev/null || true
mkdir -p /home/$U/lab && chown $U:$U /home/$U/lab && wget -q "$KIT_URL/l15-verify.sh" -O /home/$U/lab/l15-verify.sh 2>/dev/null && chown $U:$U /home/$U/lab/l15-verify.sh || true

log "FERTIG L15 ($ROLE)"
[[ $ROLE == web ]] && echo "Danach auf SRV-MON:  sudo bash l15.sh mon"
[[ $ROLE == mon ]] && echo "Prüfen auf SRV-WEB:  bash ~/lab/l15-verify.sh"
exit 0
