#!/bin/bash
# PLAN-200 L17 - Abnahme des Templates. Aufruf ohne sudo: bash ~/lab/l17-verify.sh
E=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FEHLER] $*"; E=$((E+1)); }
H=$(hostname)
if [ -d /etc/suricata ]; then
  echo "== SRV-WEB =="
  V=$(dpkg-query -W -f='${Version}' openssh-server)
  case "$V" in *ubuntu13) ok "openssh-server $V (Release, verwundbar)";; *) bad "openssh-server $V (erwartet ...ubuntu13)";; esac
  systemctl is-active -q ssh && ok "ssh laeuft" || bad "ssh laeuft nicht"
  systemctl is-enabled -q unattended-upgrades 2>/dev/null && bad "unattended-upgrades aktiv" || ok "unattended-upgrades aus"
  systemctl is-active -q suricata && ok "suricata laeuft" || bad "suricata laeuft nicht"
  grep -q '^  - interface: ens3' /etc/suricata/suricata.yaml && ok "af-packet ens3" || bad "af-packet nicht ens3"
  grep -q 'HOME_NET: "\[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12\]"' /etc/suricata/suricata.yaml && ok "HOME_NET Standard" || bad "HOME_NET nicht Standard"
  [ -s /var/lib/suricata/rules/suricata.rules ] && bad "Regeln bereits geladen" || ok "keine Regeln geladen"
  [ -f /etc/suricata/rules/local.rules ] && ok "local.rules vorhanden" || bad "local.rules fehlt"
  command -v jq >/dev/null && ok "jq" || bad "jq fehlt"
  command -v trivy >/dev/null && ok "trivy $(trivy --version 2>/dev/null | head -1)" || bad "trivy fehlt"
  sudo test -f /root/.cache/trivy/db/trivy.db && ok "Trivy-Datenbank vorhanden" || bad "Trivy-Datenbank fehlt"
  N=$(sudo docker ps --format '{{.Names}}' | grep -c '^shop-')
  [ "$N" -eq 3 ] && ok "Shop-Stack 3 Container" || bad "Shop-Stack $N Container"
  curl -sk -o /dev/null -w '%{http_code}' https://localhost | grep -q 200 && ok "Shop HTTPS 200" || bad "Shop HTTPS nicht 200"
fi
[ -f ~/Desktop/lab-cheatsheet.txt ] && ok "Cheatsheet auf dem Desktop" || bad "Cheatsheet fehlt"
echo "== $E Fehler =="
