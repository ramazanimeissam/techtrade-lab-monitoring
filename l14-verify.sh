#!/usr/bin/env bash
# PLAN-200 L14: Abnahme des Templates, auf SRV-MON ausführen:  bash ~/lab/l14-verify.sh
OK=0; FAIL=0
sudo -v || exit 1
ok(){ echo "[ OK ] $*"; OK=$((OK+1)); }
bad(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "--- Netz und R1"
chk "R1 erreichbar (10.10.100.1)"                 ping -c1 -W2 10.10.100.1
chk "SRV-WEB erreichbar (10.10.20.13)"            ping -c1 -W2 10.10.20.13
chk "Internet über R1"                            ping -c1 -W3 1.1.1.1
chk "SNMPv3 authPriv auf R1 (zbxmon)"             snmpget -v3 -l authPriv -u zbxmon -a SHA -A TechTrade-Auth1 -x AES -X TechTrade-Priv1 -t2 -r1 10.10.100.1 SNMPv2-MIB::sysName.0

echo "--- Prometheus (Endzustand L13)"
chk "Prometheus bereit (:9090)"                   curl -fs http://localhost:9090/-/ready
chk "prometheus.yml gültig (promtool)"            sudo docker exec prometheus promtool check config /config/prometheus.yml
for J in prometheus node snmp shop shop_tls; do
  H=$(curl -s http://localhost:9090/api/v1/targets | jq -r --arg j "$J" '[.data.activeTargets[] | select(.labels.job==$j) | .health] | first // "fehlt"')
  [ "$H" = up ] && ok "Job $J UP" || bad "Job $J: $H"
done
R=$(curl -s http://localhost:9090/api/v1/rules | jq '.data.groups | length')
[ "$R" = 0 ] && ok "Noch keine Alarmregeln (Startzustand)" || bad "Es sind schon $R Regelgruppen geladen"
A=$(curl -s http://localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers | length')
[ "$A" = 1 ] && ok "Prometheus kennt den Alertmanager" || bad "Alertmanager in Prometheus: $A"
if command -v prom-check >/dev/null 2>&1 || [ -e "$HOME/monitoring" ] || [ -e /opt/monitoring/config ]; then
  bad "Altlasten vorhanden (prom-check, ~/monitoring oder /opt/monitoring/config)"; else ok "Keine Altlasten"; fi

echo "--- Alertmanager und Mailpit"
chk "Alertmanager bereit (:9093)"                 curl -fs http://localhost:9093/-/ready
chk "alertmanager.yml gültig (amtool)"            sudo docker exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
chk "Mailpit Web (:8025)"                         curl -fs http://localhost:8025/api/v1/info
curl -s -X DELETE http://localhost:8025/api/v1/messages >/dev/null
curl -s -H 'Content-Type: application/json' -d '[{"labels":{"alertname":"KitTest","severity":"info"},"annotations":{"summary":"Test der Alarmkette"}}]' http://localhost:9093/api/v2/alerts >/dev/null
echo "       (Testalarm gesendet, warte 45 s auf die Mail ...)"
sleep 45
N=$(curl -s http://localhost:8025/api/v1/messages | jq '.total // 0')
[ "${N:-0}" -ge 1 ] && ok "Alarmkette Alertmanager -> Mailpit: Mail angekommen" || bad "Keine Mail in Mailpit"
curl -s -X DELETE http://localhost:8025/api/v1/messages >/dev/null

echo "--- Logs"
chk "syslog-ng läuft"                             systemctl is-active syslog-ng
if systemctl is-active rsyslog >/dev/null 2>&1; then bad "rsyslog läuft noch auf SRV-MON"; else ok "rsyslog auf SRV-MON entfernt"; fi
if sudo ss -lnup | grep -q ':514 ' || sudo ss -lntp | grep -q ':514 '; then
  bad "Port 514 ist schon offen (Empfang soll fehlen)"; else ok "Port 514 noch zu (Startzustand)"; fi
chk "Verzeichnis /etc/syslog-ng/conf.d vorhanden" test -d /etc/syslog-ng/conf.d
chk "syslog-ng.conf bindet conf.d ein"            grep -q 'conf.d' /etc/syslog-ng/syslog-ng.conf
chk "Loki bereit (:3100)"                         curl -fs http://localhost:3100/ready
chk "Alloy bereit (:12345)"                       curl -fs http://127.0.0.1:12345/-/ready
chk "Alloy hört auf 127.0.0.1:1514 (TCP)"         sh -c "sudo ss -lnt | grep -q '127.0.0.1:1514'"
chk "Loki-Regelordner /etc/loki/rules/fake leer"  sh -c '[ -z "$(ls -A /etc/loki/rules/fake)" ]'

echo "--- Grafana"
chk "Grafana bereit (:3000)"                      curl -fs http://localhost:3000/api/health
chk "Datenquelle prometheus vorhanden"            curl -fs -u admin:Gns3456 http://localhost:3000/api/datasources/name/prometheus
if curl -fs -u admin:Gns3456 http://localhost:3000/api/datasources | jq -e '.[] | select(.type=="loki")' >/dev/null; then
  bad "Datenquelle Loki existiert schon (sollen Studierende anlegen)"; else ok "Noch keine Datenquelle Loki (Startzustand)"; fi

echo "--- SRV-WEB"
chk "node_exporter (:9100)"                       sh -c 'curl -fs http://10.10.20.13:9100/metrics | grep -q node_cpu_seconds_total'
chk "Shop HTTP Release 1.0"                       sh -c 'curl -fs http://10.10.20.13/ | grep -q "Release 1.0"'
chk "iperf3-Server (Kurztest)"                    iperf3 -c 10.10.20.13 -t 2
chk "SSH auf SRV-WEB (:22)"                       nc -z -w3 10.10.20.13 22

echo "--- Zabbix (Endzustand L12)"
chk "Zabbix Web (:8080)"                          curl -fs -o /dev/null http://localhost:8080/

chk "Cheatsheet L14 ~/lab-cheatsheet.txt"         grep -q "Lektion 14" "$HOME/lab-cheatsheet.txt"

echo
echo "Ergebnis: $OK OK, $FAIL Fehler"
echo "Zusätzlich von Hand prüfen:"
echo "  SRV-WEB:  sudo tc qdisc add dev lo root netem delay 10ms && sudo tc qdisc del dev lo root   (keine Fehlermeldung)"
echo "  SRV-WEB:  systemctl is-active rsyslog                 (active)"
echo "  R1:       show configuration commands | match syslog  (kein remote-Ziel)"
exit $FAIL
