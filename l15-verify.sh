#!/usr/bin/env bash
# PLAN-200 L15 - Abnahme des Templates (auf SRV-WEB ausführen):  bash ~/lab/l15-verify.sh
MON=10.10.100.20
OKC=0; ERR=0
ok(){ echo "OK      $*"; OKC=$((OKC+1)); }
bad(){ echo "FEHLER  $*"; ERR=$((ERR+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
D="sudo docker"

echo "--- SRV-WEB: Docker"
chk "Docker läuft"                       systemctl is-active docker
chk "Docker Compose vorhanden"           $D compose version
for i in techtrade/shop:1.4 techtrade/shop:1.5 techtrade/shop:1.6 nginx:1.30.5-alpine nginx:1.30.6-alpine postgres:16.15-alpine ghcr.io/google/cadvisor:0.60.5 python:3.12-slim; do
  chk "Image $i"                         $D image inspect $i
done
chk "keine Log-Rotation konfiguriert (Ausgangszustand)"  test ! -e /etc/docker/daemon.json
chk "gns3 nicht in Gruppe docker"        bash -c '! id -nG gns3 | grep -qw docker'

echo "--- SRV-WEB: Shop-Stack (Ausgangszustand: nicht gestartet)"
chk "/opt/shop/compose.yaml gültig"      bash -c "cd /opt/shop && sudo docker compose config -q"
chk ".env: SHOP_VERSION=1.4"             grep -qx 'SHOP_VERSION=1.4' /opt/shop/.env
chk ".env: DB_HOST=db"                   grep -qx 'DB_HOST=db' /opt/shop/.env
chk "keine Container vorhanden"          bash -c "test -z \"\$($D ps -aq)\""
chk "kein Volume shop_dbdata"            bash -c "! $D volume inspect shop_dbdata"
chk "Ordner /backup vorhanden"           test -d /backup
chk "nginx auf dem Host gestoppt"        bash -c '! systemctl is-active nginx'
chk "nginx auf dem Host deaktiviert"     bash -c '! systemctl is-enabled nginx'
chk "Ports 80/443 frei"                  bash -c '! sudo ss -tlnH | grep -Eq ":(80|443) "'
chk "Shop-Zertifikat vorhanden"          test -s /etc/ssl/techtrade/shop.crt
chk "node_exporter läuft"                systemctl is-active prometheus-node-exporter

echo "--- SRV-WEB: Übungsdateien (Ausgangszustand)"
chk "Dockerfile-Übung vorhanden (FROM python:latest)"   grep -q '^FROM python:latest' /opt/lab/uebung/Dockerfile
chk "index.html der Übung vorhanden"                    test -s /opt/lab/uebung/index.html
chk "cAdvisor-Compose vorhanden (image :latest)"        grep -q 'cadvisor:latest' /opt/cadvisor/compose.yaml
chk "cAdvisor-Compose gültig"                           sudo docker compose -f /opt/cadvisor/compose.yaml config -q

echo "--- SRV-MON (per Netz)"
R=$(curl -s --max-time 5 http://$MON:9090/api/v1/rules)
chk "Prometheus: Regel ShopNichtVerfuegbar geladen"  grep -q ShopNichtVerfuegbar <<<"$R"
chk "Prometheus: Regel ZielNichtErreichbar geladen"  grep -q ZielNichtErreichbar <<<"$R"
T=$(curl -s --max-time 5 http://$MON:9090/api/v1/targets)
chk "Prometheus: Jobs shop und node vorhanden"       bash -c "grep -q '\"job\":\"shop\"' <<<'$T' && grep -q '\"job\":\"node\"' <<<'$T'"
chk "Prometheus: noch kein Job cadvisor (Ausgangszustand)"  bash -c "! grep -q '\"job\":\"cadvisor\"' <<<'$T'"
A=$(curl -s --max-time 5 http://$MON:9093/api/v2/status)
chk "Alertmanager: Empfänger betrieb"                grep -q betrieb <<<"$A"
chk "Mailpit erreichbar"                              curl -s --max-time 5 -o /dev/null http://$MON:8025/

echo "--- Cheatsheet"
chk "Cheatsheet auf SRV-WEB"             test -s /home/gns3/lab-cheatsheet.txt

echo
echo "Ergebnis: $OKC OK, $ERR Fehler"
