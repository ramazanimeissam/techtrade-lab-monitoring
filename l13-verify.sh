#!/usr/bin/env bash
# PLAN-200 L13: Abnahme des Templates, auf SRV-MON ausfuehren:  bash ~/lab/l13-verify.sh
OK=0; FAIL=0
ok(){ echo "[ OK ] $*"; OK=$((OK+1)); }
bad(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# --- Netz und R1
chk "R1 Mgmt erreichbar (10.10.100.1)"           ping -c1 -W2 10.10.100.1
chk "SRV-WEB erreichbar ueber R1 (10.10.20.13)"   ping -c1 -W2 10.10.20.13
chk "Internet / NAT ueber R1"                     ping -c1 -W3 1.1.1.1
chk "SNMPv3 authPriv auf R1 (zbxmon)"             snmpget -v3 -l authPriv -u zbxmon -a SHA -A TechTrade-Auth1 -x AES -X TechTrade-Priv1 -t2 -r1 10.10.100.1 SNMPv2-MIB::sysName.0
if snmpget -v2c -c techtrade-ro -t2 -r0 10.10.100.1 SNMPv2-MIB::sysName.0 >/dev/null 2>&1; then
  bad "SNMPv2c antwortet noch (soll entfernt sein)"; else ok "SNMPv2c entfernt"; fi

# --- Prometheus-Stack
chk "Prometheus bereit (:9090)"                   curl -fs http://localhost:9090/-/ready
chk "Grafana bereit (:3000)"                      curl -fs http://localhost:3000/api/health
chk "Grafana-Login admin / Gns3456"               curl -fs -u admin:Gns3456 http://localhost:3000/api/user
N=$(curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length')
[ "$N" = 1 ] && ok "Prometheus: nur das Ziel 'prometheus' (Startzustand)" || bad "Prometheus: $N Ziele, erwartet 1"
chk "blackbox: Shop HTTP Probe erfolgreich"        sh -c 'curl -fs "http://localhost:9115/probe?module=shop_http&target=http://10.10.20.13/" | grep -q "^probe_success 1"'
chk "blackbox: Shop HTTPS Probe erfolgreich"       sh -c 'curl -fs "http://localhost:9115/probe?module=shop_https&target=https://10.10.20.13/" | grep -q "^probe_success 1"'
chk "snmp_exporter laeuft (:9116)"                 curl -fs http://localhost:9116/
if curl -fs "http://localhost:9116/snmp?target=10.10.100.1&module=if_mib&auth=techtrade_v3" >/dev/null 2>&1; then
  bad "snmp_exporter kennt techtrade_v3 schon (soll fehlen)"; else ok "snmp_exporter: Zugang techtrade_v3 noch nicht eingerichtet"; fi
chk "Hilfsbefehle prom-check/prom-reload/snmp-reload" sh -c 'command -v prom-check && command -v prom-reload && command -v snmp-reload'
chk "prom-check: Konfiguration gueltig"           prom-check
chk "~/monitoring/prometheus.yml beschreibbar"    test -w "$HOME/monitoring/prometheus.yml"
chk "~/monitoring/snmp-auth.yml beschreibbar"     test -w "$HOME/monitoring/snmp-auth.yml"

# --- SRV-WEB
chk "node_exporter auf SRV-WEB (:9100)"           sh -c 'curl -fs http://10.10.20.13:9100/metrics | grep -q node_cpu_seconds_total'
chk "iperf3-Server auf SRV-WEB (Kurztest)"        iperf3 -c 10.10.20.13 -t 2
chk "Shop HTTP: 'TechTrade Shop', Release 1.0"   sh -c 'curl -fs http://10.10.20.13/ | grep -q "Release 1.0"'
chk "Shop HTTPS"                                  curl -kfs -o /dev/null https://10.10.20.13/

# --- Zabbix
API=http://localhost:8080/api_jsonrpc.php
T=$(curl -s -H 'Content-Type: application/json-rpc' -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' $API | jq -r '.result // empty')
if [ -n "$T" ]; then
  Z(){ curl -s -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $T" -d "$1" $API; }
  for H in R1 SRV-WEB; do
    A=$(Z "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$H\"]},\"selectInterfaces\":[\"available\"],\"output\":[\"host\"]},\"id\":2}" | jq -r '.result[0].interfaces[0].available // "fehlt"')
    [ "$A" = 1 ] && ok "Zabbix: $H verfuegbar" || bad "Zabbix: $H nicht verfuegbar (available=$A)"
  done
  C=$(Z '{"jsonrpc":"2.0","method":"item.get","params":{"host":"R1","search":{"key_":"net.if.in["},"startSearch":true,"countOutput":true},"id":3}' | jq -r '.result')
  [ "${C:-0}" -gt 0 ] 2>/dev/null && ok "Zabbix: $C Interface-Items auf R1 (Discovery gelaufen)" || bad "Zabbix: keine Interface-Items auf R1 (Discovery noch nicht gelaufen?)"
  W=$(Z '{"jsonrpc":"2.0","method":"httptest.get","params":{"filter":{"name":["Shop"]},"countOutput":true},"id":4}' | jq -r '.result')
  [ "$W" = 1 ] && ok "Zabbix: Web-Szenario Shop vorhanden" || bad "Zabbix: Web-Szenario Shop fehlt"
  Z '{"jsonrpc":"2.0","method":"user.logout","params":{},"id":5}' >/dev/null
else bad "Zabbix-API Login"; fi

chk "Cheatsheet L13 ~/lab-cheatsheet.txt"         grep -q "Lektion 13" "$HOME/lab-cheatsheet.txt"

echo
echo "Ergebnis: $OK OK, $FAIL Fehler"
echo "Zusaetzlich auf SRV-WEB von Hand pruefen:"
echo "  ls /opt/lab/release/                 (1.0, 1.1 und 1.2)"
echo "  dpkg -l techtrade-shop | tail -1     (1.0)"
exit $FAIL
