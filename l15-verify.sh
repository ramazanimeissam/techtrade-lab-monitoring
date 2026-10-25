#!/usr/bin/env bash
# PLAN-200 L15 - Abnahme des Templates (auf SRV-WEB ausführen):  bash ~/lab/l15-verify.sh
# Stand 26.10.2026 (Befunde 1-39 umgesetzt)
MON=10.10.100.20
OKC=0; ERR=0
ok(){ echo "OK      $*"; OKC=$((OKC+1)); }
bad(){ echo "FEHLER  $*"; ERR=$((ERR+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
D="sudo docker"

echo "--- SRV-WEB: Docker"
chk "Docker läuft"                       systemctl is-active docker
chk "Docker Compose vorhanden"           $D compose version
for i in techtrade/shop:1.4 techtrade/shop:1.5 nginx:1.30.5-alpine nginx:1.30.6-alpine postgres:16.15-alpine ghcr.io/google/cadvisor:0.60.5 grafana/alloy:v1.17.1; do
  chk "Image $i"                         $D image inspect $i
done
chk "kein Image techtrade/shop:1.6 (Kür gestrichen)"   bash -c "! $D image inspect techtrade/shop:1.6"
chk "kein Image techtrade/nginx (bauen die Studierenden)" bash -c "test -z \"\$($D images -q techtrade/nginx)\""
chk "keine Log-Rotation konfiguriert (Ausgangszustand)"  test ! -e /etc/docker/daemon.json
chk "gns3 nicht in Gruppe docker"        bash -c '! id -nG gns3 | grep -qw docker'

echo "--- SRV-WEB: Shop-Stack (Ausgangszustand: nicht gestartet)"
chk "/opt/shop/compose.yaml gültig"      bash -c "cd /opt/shop && sudo docker compose config -q"
chk "compose.yaml: Zeitzone /etc/localtime für proxy"  grep -q '/etc/localtime:/etc/localtime:ro' /opt/shop/compose.yaml
chk "Shop-Image: Zeitzone Europe/Zurich"  bash -c "$D run --rm --entrypoint date techtrade/shop:1.4 +%Z | grep -Eq 'CET|CEST'"
chk ".env: SHOP_VERSION=1.4"             grep -qx 'SHOP_VERSION=1.4' /opt/shop/.env
chk ".env: DB_HOST=db"                   grep -qx 'DB_HOST=db' /opt/shop/.env
chk "keine Shop-Container vorhanden"     bash -c "test -z \"\$($D ps -aq --filter label=com.docker.compose.project=shop)\""
chk "kein Volume shop_dbdata"            bash -c "! $D volume inspect shop_dbdata"
chk "Ordner /backup vorhanden und leer"  bash -c 'test -d /backup && test -z "$(ls -A /backup)"'
chk "nginx auf dem Host gestoppt"        bash -c '! systemctl is-active nginx'
chk "nginx auf dem Host deaktiviert"     bash -c '! systemctl is-enabled nginx'
chk "Ports 80/443 frei"                  bash -c '! sudo ss -tlnH | grep -Eq ":(80|443) "'
chk "Shop-Zertifikat vorhanden"          test -s /etc/ssl/techtrade/shop.crt
chk "node_exporter läuft"                systemctl is-active prometheus-node-exporter

echo "--- SRV-WEB: Übungsdateien (Ausgangszustand)"
chk "Dockerfile-Übung: nur FROM nginx:latest"           bash -c "grep -v '^#' /opt/lab/uebung/Dockerfile | grep -v '^\$' | grep -qx 'FROM nginx:latest' && test \$(grep -v '^#' /opt/lab/uebung/Dockerfile | grep -vc '^\$') -eq 1"
chk "security.conf vorhanden (server_tokens, 3 Header)"  bash -c "grep -q '^server_tokens off;' /opt/lab/uebung/security.conf && test \$(grep -c '^add_header' /opt/lab/uebung/security.conf) -eq 3"
chk "keine alte Python-Übung (index.html)"               test ! -e /opt/lab/uebung/index.html
chk "cAdvisor-Compose vorhanden (image :latest)"         grep -q 'cadvisor:latest' /opt/cadvisor/compose.yaml
chk "cAdvisor-Compose gültig"                            sudo docker compose -f /opt/cadvisor/compose.yaml config -q
chk "cAdvisor nicht gestartet"                           bash -c "test -z \"\$($D ps -aq --filter name=cadvisor)\""

echo "--- SRV-WEB: Alloy (Container-Logs an Loki, vom Kit eingerichtet)"
chk "Alloy-Container läuft"              bash -c "$D ps --filter name=alloy-alloy-1 --filter status=running -q | grep -q ."
chk "Alloy ohne Container-Metriken (nur Logs)"  bash -c "! grep -q 'prometheus' /opt/alloy/config.alloy"
chk "Alloy bereit (Weboberfläche :12345)"  curl -sf --max-time 5 http://localhost:12345/-/ready
chk "Loki auf SRV-MON erreichbar"        curl -sf --max-time 5 http://$MON:3100/ready
chk "Logs von SRV-WEB kommen in Loki an" bash -c "curl -s --max-time 5 -G http://$MON:3100/loki/api/v1/label/container/values --data-urlencode 'start='\$(date -d '-1 hour' +%s)'000000000' | grep -q alloy-alloy-1"

echo "--- SRV-MON (per Netz)"
R=$(curl -s --max-time 5 http://$MON:9090/api/v1/rules)
chk "Prometheus: Regel ShopNichtVerfuegbar geladen"  grep -q ShopNichtVerfuegbar <<<"$R"
chk "Prometheus: Regel ZielNichtErreichbar geladen"  grep -q ZielNichtErreichbar <<<"$R"
chk "Prometheus: noch keine Container-Regeln (Ausgangszustand)"  bash -c "! grep -qE 'ShopContainerFehlt|ContainerSpeicherKnapp|ContainerNeustarts' <<<'$R'"
T=$(curl -s --max-time 5 http://$MON:9090/api/v1/targets)
chk "Prometheus: Jobs shop und node vorhanden"       bash -c "grep -q '\"job\":\"shop\"' <<<'$T' && grep -q '\"job\":\"node\"' <<<'$T'"
chk "Prometheus: noch kein Job cadvisor (Ausgangszustand)"  bash -c "! grep -q '\"job\":\"cadvisor\"' <<<'$T'"
A=$(curl -s --max-time 5 http://$MON:9093/api/v2/status)
chk "Alertmanager: Empfänger betrieb"                grep -q betrieb <<<"$A"
chk "Mailpit erreichbar"                              curl -s --max-time 5 -o /dev/null http://$MON:8025/
GF="curl -sf --max-time 5 -u admin:Gns3456 http://$MON:3000"
chk "Grafana: Datenquelle prometheus"                $GF/api/datasources/name/prometheus
chk "Grafana: Datenquelle loki"                      $GF/api/datasources/name/loki
chk "Grafana: Dashboard Shop-Plattform"              $GF/api/dashboards/uid/shop-plattform

echo "--- Cheatsheet"
chk "Cheatsheet auf SRV-WEB"             test -s /home/gns3/lab-cheatsheet.txt
chk "Cheatsheet ist Stand 26.10. (keine Kür/Auftrag 6)"  bash -c "! grep -qE 'KÜR|ÜBERPRÜFEN UND WEITERENTWICKELN' /home/gns3/lab-cheatsheet.txt"

echo
echo "Ergebnis: $OKC OK, $ERR Fehler"
