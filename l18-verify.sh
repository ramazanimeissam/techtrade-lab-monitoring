#!/bin/bash
# PLAN-200 L18 - Abnahme des Templates. Aufruf ohne sudo: bash ~/lab/l18-verify.sh
E=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FEHLER] $*"; E=$((E+1)); }

if [ -d /opt/shop ]; then
  echo "== SRV-WEB =="
  [ "$(nproc)" -ge 2 ] && ok "$(nproc) CPUs" || bad "nur $(nproc) CPU (mindestens 2 nötig)"
  systemctl is-active -q suricata && bad "suricata läuft noch" || ok "suricata gestoppt"
  command -v iperf3 >/dev/null && ok "iperf3" || bad "iperf3 fehlt"
  sudo docker image inspect techtrade/shop:2.0 >/dev/null 2>&1 && ok "Image techtrade/shop:2.0" || bad "Image techtrade/shop:2.0 fehlt"
  N=$(sudo docker ps --format '{{.Names}}' | grep -c '^shop-')
  [ "$N" -eq 4 ] && ok "Shop-Stack 4 Container (proxy, app1, app2, db)" || bad "Shop-Stack $N Container (erwartet 4)"
  sudo docker ps --format '{{.Names}}' | grep -q '^shop-app3' && bad "app3 existiert schon" || ok "kein app3"
  C=$(sudo docker inspect -f '{{.HostConfig.NanoCpus}}' shop-app1-1 2>/dev/null)
  [ "$C" = "250000000" ] && ok "app1 CPU-Limit 0.25" || bad "app1 CPU-Limit: $C"
  grep -q 'weight' /opt/shop/nginx/default.conf && bad "default.conf enthält schon weight" || ok "default.conf ohne Gewichte"
  grep -q 'proxy_cache' /opt/shop/nginx/default.conf && bad "default.conf enthält schon Cache" || ok "default.conf ohne Cache"
  B=$(for i in 1 2 3 4 5 6; do curl -sk -D - -o /dev/null https://localhost/ | grep -i '^x-backend'; done | sort -u | wc -l)
  [ "$B" -eq 2 ] && ok "Round Robin über app1 und app2" || bad "X-Backend: $B verschiedene Instanzen"
  curl -sk -o /dev/null -w '%{http_code}' https://localhost/static/shop.css | grep -q 200 && ok "statische Datei /static/shop.css" || bad "/static/shop.css nicht 200"
  sudo docker ps --format '{{.Names}}' | grep -q cadvisor && ok "cAdvisor läuft" || bad "cAdvisor läuft nicht"
  curl -sf http://localhost:8081/metrics | grep -q 'name="shop-app1-1"' && ok "cAdvisor misst shop-app1-1" || bad "cAdvisor: keine Werte für shop-app1-1"
  sudo docker compose -f /opt/shop/compose.yaml logs app1 2>/dev/null | grep -o 'Rechenzeit pro Seite.*' | tail -1
fi

if [ -d /etc/prometheus ]; then
  echo "== SRV-MON =="
  command -v iperf3 >/dev/null && ok "iperf3" || bad "iperf3 fehlt"
  command -v localc >/dev/null || command -v libreoffice >/dev/null && ok "LibreOffice" || bad "LibreOffice fehlt"
  sudo docker image inspect grafana/k6:1.3.0 >/dev/null 2>&1 && ok "Image grafana/k6:1.3.0" || bad "k6-Image fehlt"
  [ -f ~/lab/k6/weihnachten.js ] && ok "~/lab/k6/weihnachten.js" || bad "weihnachten.js fehlt"
  [ -f ~/lab/kapazitaet.xlsx ] && ok "~/lab/kapazitaet.xlsx" || bad "kapazitaet.xlsx fehlt"
  curl -s 'http://localhost:9090/api/v1/query?query=up{job="cadvisor"}' | grep -q '"1"\]' && ok "Prometheus: cadvisor UP" || bad "Prometheus: cadvisor nicht UP"
  curl -s 'http://localhost:9090/api/v1/query?query=up{job="snmp"}' | grep -q '"1"\]' && ok "Prometheus: snmp UP" || bad "Prometheus: snmp nicht UP"
  curl -sf -u admin:Gns3456 http://localhost:3000/api/dashboards/uid/kapazitaet-shop >/dev/null && ok "Dashboard Kapazität Shop" || bad "Dashboard fehlt"
  curl -sk -o /dev/null -w '%{http_code}' https://10.10.20.13/ | grep -q 200 && ok "Shop von SRV-MON erreichbar" || bad "Shop von SRV-MON nicht erreichbar"
fi

[ -f ~/Desktop/lab-cheatsheet.txt ] && ok "Cheatsheet auf dem Desktop" || bad "Cheatsheet fehlt"
echo "== $E Fehler =="
