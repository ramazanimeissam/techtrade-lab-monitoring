#!/usr/bin/env bash
# PLAN-200 L12: Abnahme des Templates, auf SRV-MON ausfuehren:  bash ~/lab/verify.sh
OK=0; FAIL=0
ok(){ echo "[ OK ] $*"; OK=$((OK+1)); }
bad(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

chk "R1 Mgmt erreichbar (10.10.100.1)"        ping -c1 -W2 10.10.100.1
chk "SRV-WEB erreichbar ueber R1 (10.10.20.13)" ping -c1 -W2 10.10.20.13
chk "Internet / NAT ueber R1"                  ping -c1 -W3 1.1.1.1
chk "DNS"                                       getent hosts repo.zabbix.com
chk "SNMPv2c auf R1 (techtrade-ro)"             snmpget -v2c -c techtrade-ro -t2 -r1 10.10.100.1 SNMPv2-MIB::sysName.0
if snmpget -v3 -l noAuthNoPriv -u zbxmon -t2 -r0 10.10.100.1 SNMPv2-MIB::sysName.0 2>&1 | grep -q 'sysName'; then
  bad "SNMPv3 ist schon konfiguriert (soll im Startzustand fehlen)"; else ok "SNMPv3 noch nicht konfiguriert"; fi
chk "Zabbix-Frontend :8080"                     curl -fs -o /dev/null http://localhost:8080/
chk "Zabbix agent2 auf SRV-WEB"                 sh -c '[ "$(zabbix_get -s 10.10.20.13 -k agent.ping)" = 1 ]'
chk "Shop HTTP mit 'TechTrade Shop' (Release 1.0)" sh -c 'curl -fs http://10.10.20.13/ | grep -q "TechTrade Shop"'
chk "Shop HTTPS"                                curl -kfs -o /dev/null https://10.10.20.13/

N=$(curl -s -H 'Content-Type: application/json-rpc' -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' http://localhost:8080/api_jsonrpc.php \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null)
if [ -n "$N" ]; then
  C=$(curl -s -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $N" \
      -d '{"jsonrpc":"2.0","method":"host.get","params":{"countOutput":true},"id":2}' http://localhost:8080/api_jsonrpc.php \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])')
  [ "$C" = 0 ] && ok "Zabbix: keine Hosts erfasst" || bad "Zabbix: $C Host(s) vorhanden, erwartet 0"
  curl -s -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $N" \
      -d '{"jsonrpc":"2.0","method":"user.logout","params":{},"id":3}' http://localhost:8080/api_jsonrpc.php >/dev/null
else bad "Zabbix-API Login"; fi

chk "Lastdaten ~/lab/shop_last_7x24.csv"        test -s "$HOME/lab/shop_last_7x24.csv"
chk "Cheatsheet ~/lab-cheatsheet.txt"           test -s "$HOME/lab-cheatsheet.txt"
chk "Wireshark installiert"                      command -v wireshark
chk "LibreOffice Calc installiert"               command -v localc

echo
echo "Ergebnis: $OK OK, $FAIL Fehler"
echo "Zusaetzlich auf SRV-WEB von Hand pruefen:"
echo "  apt list --upgradable 2>/dev/null | grep -c -- -security   (> 0)"
echo "  ls /opt/lab/release/                                        (1.0 und 1.1)"
echo "  systemctl is-enabled unattended-upgrades                    (disabled)"
exit $FAIL
