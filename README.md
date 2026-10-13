# PLAN-200 L12 – Template-Aufbau SNMP + Zabbix (30 Min)

Kit-Repo (öffentlich): `https://github.com/ramazanimeissam/techtrade-lab-monitoring`
Raw-URL: `https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main`

Dateien: `setup.sh` (Rollen `mon` | `web`), `r1.vyos`, `verify.sh`, `lab-cheatsheet.txt`, `shop_last_7x24.csv`

## 1 · Knoten und Verkabelung

| Knoten | Image | RAM | Verbindung |
|---|---|---|---|
| Cloud1 | Cloud | – | R1 eth0 |
| R1 | vyos2025-1 | 1 GB | eth0 → Cloud1 · eth1 → SRV-MON ens3 · eth2 → SRV-WEB ens3 |
| SRV-MON | xubuntu2404 | 4 GB | ens3 → R1 eth1 |
| SRV-WEB | xubuntu2404 | 2 GB | ens3 → R1 eth2 |

Kein Switch nötig. Total ca. 7 GB RAM.

## 2 · Ablauf

| Min | Schritt |
|---|---|
| 0–3 | Knoten platzieren, verkabeln, starten |
| 3–8 | R1 tippen (`r1.vyos`) |
| 8–10 | SRV-MON und SRV-WEB: temporäres Netz, `setup.sh` starten (parallel) |
| 10–22 | Warten (Docker-Images, Pakete). Reihenfolge, wer zuerst fertig ist, spielt keine Rolle |
| 22–25 | `verify.sh` auf SRV-MON, Handprüfungen SRV-WEB |
| 25–30 | Aufräumen, hw-id strip, Freeze |

### 2.1 · R1 (Konsole, tippen)

Inhalt von `r1.vyos` eintippen (15 `set`-Zeilen), dann `commit`, `save`, `exit`.
Prüfen: `show interfaces` → eth0 hat DHCP-Adresse, eth1 .1, eth2 .1. `ping 1.1.1.1`.

### 2.2 · SRV-MON und SRV-WEB (Terminal)

SRV-MON:
```
sudo ip addr add 10.10.100.20/24 dev ens3
sudo ip route add default via 10.10.100.1
sudo resolvectl dns ens3 1.1.1.1
wget https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main/setup.sh
sudo bash setup.sh mon
```

SRV-WEB:
```
sudo ip addr add 10.10.20.13/24 dev ens3
sudo ip route add default via 10.10.20.1
sudo resolvectl dns ens3 1.1.1.1
wget https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main/setup.sh
sudo bash setup.sh web
```

Falls `ip addr add` meldet, die Adresse existiere schon oder es läuft DHCP: egal, das Skript schreibt Netplan neu.

### 2.3 · Abnahme

Auf SRV-MON (nach Ab- und Anmelden): `bash ~/lab/verify.sh` → **0 Fehler**.

Auf SRV-WEB von Hand:
```
apt list --upgradable 2>/dev/null | grep -c -- -security    # > 0
ls /opt/lab/release/                                         # 1.0 und 1.1
dpkg -l techtrade-shop | tail -1                             # 1.0
systemctl is-enabled unattended-upgrades                     # disabled
zabbix_agent2 -t agent.ping                                  # 1
```

Kurz im Browser auf SRV-MON: `http://localhost:8080`, Login `Admin`/`zabbix`, *Data collection → Hosts* ist leer.

### 2.4 · Aufräumen und Freeze

1. **Cheatsheet** liegt auf beiden Servern unter `~/lab-cheatsheet.txt` (macht `setup.sh`). Kontrollieren.
2. SRV-MON: `rm -f ~/lab/verify.sh` (Studierende sollen es nicht sehen), Firefox-Verlauf löschen, `history -c`.
3. SRV-WEB: `rm -f ~/setup.sh`, `history -c`. SRV-MON ebenso `rm -f ~/setup.sh`.
4. **R1 hw-id strip** (im Normalmodus, nach dem letzten `save`):
   ```
   sudo sed -i '/hw-id/d' /config/config.boot
   grep -c hw-id /config/config.boot     # 0
   ```
   Danach **kein `save` mehr** auf R1.
5. Alle Knoten herunterfahren (`sudo poweroff`, R1 `poweroff`), Template einfrieren.
6. **Test-Clone** starten: R1 `show interfaces summary` (Beschreibungen WAN/MGMT/SERVER vorhanden), dann auf SRV-MON `verify.sh` erneut (vor dem Löschen eine Kopie behalten oder neu laden).

## 3 · Was das Template absichtlich enthält

| Element | Zweck im Lab |
|---|---|
| R1 nur SNMPv2c (`techtrade-ro`, nur von .20) | Auftrag 0/1: v2c im Klartext sehen, v3 selbst einrichten |
| Zabbix ohne Hosts | Auftrag 2: Hosts selbst aufnehmen |
| Ausstehende Updates, unattended-upgrades aus | Auftrag 4: Security-Updates messen |
| Zertifikat mit 20 Tagen, bei **jedem Boot** neu | Auftrag 4: Trigger < 30 Tage feuert immer |
| `techtrade-shop` 1.0 installiert, 1.1 bereit | Auftrag 7: 1.1 entfernt «TechTrade Shop» von der Seite → Web-Szenario schlägt fehl (HTTP 200!) → Rollback |
| `shop_last_7x24.csv` | Auftrag 6: ruhigstes Fenster So 02–05 Uhr; werktags 06 Uhr ERP-Import als Falle |

## 4 · Stolpersteine

- Zabbix-Images ziehen dauert bei langsamer Leitung am längsten. Bei Abbruch: `cd /opt/zabbix && sudo docker compose up -d` erneut.
- `apt` blockiert mit Lock: `unattended-upgrades` lief noch. Das Skript wartet bis 5 Min (`Lock::Timeout`).
- Zabbix-Template-Name in 7.0: **Linux by SNMP** (für R1), **Linux by Zabbix agent** (für SRV-WEB).
- Docker-Container erreichen R1 und SRV-WEB über NAT des Hosts; Quelle ist 10.10.100.20. Deshalb passen `client` (SNMP) und `Server=` (Agent).
