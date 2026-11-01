#!/usr/bin/env bash
# PLAN-200 L16 - Abnahme des Templates. Auf jedem System ausführen:  bash ~/lab/l16-verify.sh
# Prüft je nach Hostname SRV-DNS, SRV-WEB oder SRV-MON (Ausgangszustand für die Studierenden).
OKC=0; ERR=0
ok(){ echo "OK      $*"; OKC=$((OKC+1)); }
bad(){ echo "FEHLER  $*"; ERR=$((ERR+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
H=$(hostname)

common(){
  chk "Cheatsheet vorhanden"                    test -s ~/lab-cheatsheet.txt
  chk "Internet erreichbar (1.1.1.1)"          ping -c1 -W2 1.1.1.1
}

case "$H" in
SRV-DNS)
  echo "--- SRV-DNS"
  chk "Adresse 10.10.30.53"                    bash -c "ip -4 addr show ens3 | grep -q '10.10.30.53/24'"
  chk "Gateway R1 10.10.30.1 erreichbar"        ping -c1 -W2 10.10.30.1
  chk "SRV-WEB erreichbar"                     ping -c1 -W2 10.10.20.13
  chk "SRV-MON erreichbar"                     ping -c1 -W2 10.10.100.20
  chk "BIND (named) läuft"                     systemctl is-active named
  chk "BIND-Konfiguration gültig"              sudo named-checkconf
  chk "keine eigenen Zonen (named.conf.local leer)" bash -c "! grep -v '^//' /etc/bind/named.conf.local | grep -q zone"
  chk "kein Forwarder konfiguriert"            bash -c "! grep -q 'forwarders *{ *[0-9]' /etc/bind/named.conf.options"
  chk "kein Statistik-Kanal konfiguriert"      bash -c "! grep -rq statistics-channels /etc/bind/"
  chk "Ordner /etc/bind/zones leer"            bash -c 'test -d /etc/bind/zones && test -z "$(ls -A /etc/bind/zones)"'
  chk "bind_exporter läuft"                    systemctl is-active prometheus-bind-exporter
  chk "bind_exporter: Port 9119 antwortet"     curl -sf http://localhost:9119/metrics
  chk "bind_exporter: bind_up 0 (Statistik-Kanal aus)" bash -c "curl -s http://localhost:9119/metrics | grep -qx 'bind_up 0'"
  chk "Wireshark installiert"                  command -v wireshark
  chk "tshark installiert"                     command -v tshark
  chk "gns3 in Gruppe wireshark"               bash -c 'id -nG gns3 | grep -qw wireshark'
  chk "dumpcap darf mitschneiden (Capabilities)" bash -c 'getcap /usr/bin/dumpcap | grep -q cap_net_raw'
  chk "rndc funktioniert"                      sudo rndc status
  echo "Versionen: $(named -v)  |  $(prometheus-bind-exporter --version 2>&1 | head -1)  |  $(tshark -v 2>/dev/null | head -1)"
  common ;;
SRV-WEB)
  echo "--- SRV-WEB"
  chk "SRV-DNS erreichbar"                     ping -c1 -W2 10.10.30.53
  chk "Resolver 1.1.1.1 (Ausgangszustand)"     bash -c "resolvectl dns ens3 | grep -q 1.1.1.1"
  chk "keine Suchdomäne (Ausgangszustand)"     bash -c "! resolvectl domain ens3 | grep -q techtrade"
  chk "dnsperf installiert"                    command -v dnsperf
  chk "dig installiert"                        command -v dig
  chk "tshark installiert"                     command -v tshark
  chk "gns3 in Gruppe wireshark"               bash -c 'id -nG gns3 | grep -qw wireshark'
  chk "Anfragemix: 100 Zeilen"                 bash -c 'test $(wc -l < /opt/lab/dns/anfragen.txt) -eq 100'
  chk "Shop-Stack: 3 Container laufen"         bash -c 'test $(sudo docker ps -q --filter label=com.docker.compose.project=shop | wc -l) -eq 3'
  chk "Shop antwortet (HTTP 200)"              bash -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q 200'
  chk "externe Auflösung über 1.1.1.1"         dig +short +time=3 @1.1.1.1 www.example.com
  echo "Versionen: $(dnsperf -h 2>&1 | grep -m1 -i version)  |  $(tshark -v 2>/dev/null | head -1)"
  common ;;
SRV-MON)
  echo "--- SRV-MON"
  chk "SRV-DNS erreichbar"                     ping -c1 -W2 10.10.30.53
  chk "Resolver 1.1.1.1 (Ausgangszustand)"     bash -c "resolvectl dns ens3 | grep -q 1.1.1.1"
  chk "Prometheus: Job bind konfiguriert"      grep -q 'job_name: bind' /etc/prometheus/prometheus.yml
  chk "Prometheus: Ziel bind UP"               bash -c "curl -s 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22bind%22%7D' | grep -q '\"1\"\]'"
  chk "Prometheus: bind_up = 0 (Statistik-Kanal aus)" bash -c "curl -s 'http://localhost:9090/api/v1/query?query=bind_up' | grep -q '\"0\"\]'"
  chk "Grafana: Dashboard DNS-Dienst"          curl -sf -u admin:Gns3456 http://localhost:3000/api/dashboards/uid/dns-dienst
  chk "Mailpit: Posteingang leer"              bash -c "curl -s http://localhost:8025/api/v1/messages | grep -q '\"total\":0'"
  chk "LibreOffice Calc installiert"           command -v localc
  chk "Berichtsvorlage vorhanden"              test -s ~/lab/bericht_oktober.xlsx
  chk "Shop von SRV-MON erreichbar"            bash -c 'curl -s -o /dev/null -w "%{http_code}" http://10.10.20.13/ | grep -q 200'
  common ;;
*) echo "Unbekannter Host $H - erwartet SRV-DNS, SRV-WEB oder SRV-MON"; exit 1 ;;
esac

echo; echo "Ergebnis: $OKC OK, $ERR Fehler"
[[ $ERR -eq 0 ]]
