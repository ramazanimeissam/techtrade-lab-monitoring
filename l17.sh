#!/bin/bash
# PLAN-200 L17 - Kit: Threat Intelligence, Schwachstellen, Suricata
# Aufruf: sudo bash l17.sh web | mon | kali
set -u
ROLE="${1:-}"
REPO="https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-monitoring/main"
PW="Gns3456"
ok()   { echo "[OK]   $*"; }
fail() { echo "[FEHLER] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

cheatsheet() {   # $1 = Benutzer
  local h; h=$(getent passwd "$1" | cut -d: -f6)
  mkdir -p "$h/Desktop"
  wget -q "$REPO/l17-cheatsheet.txt" -O "$h/Desktop/lab-cheatsheet.txt" && ok "Cheatsheet auf $h/Desktop" || fail "Cheatsheet nicht geladen"
  chown -R "$1:$1" "$h/Desktop"
}

case "$ROLE" in
web)
  echo "== SRV-WEB =="
  # automatische Updates aus, sonst wird OpenSSH wieder aktualisiert
  systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
  ok "automatische Updates deaktiviert"
  apt-get update -q
  apt-get install -y -q jq suricata wget gpg >/dev/null && ok "suricata, jq installiert" || fail "apt suricata/jq"

  # OpenSSH auf das Release-Paket von 24.04 setzen (verwundbar fuer CVE-2024-6387)
  REL=$(apt-cache madison openssh-server | awk -F'|' '$3 ~ /noble\/main/ && $3 !~ /updates|security/ {gsub(/ /,"",$2); print $2; exit}')
  echo "Release-Version openssh-server: $REL"
  apt-get install -y -q --allow-downgrades openssh-server="$REL" openssh-client="$REL" openssh-sftp-server="$REL" >/dev/null \
    && ok "openssh-server $REL installiert" || fail "Downgrade openssh"
  printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/10-lab.conf
  systemctl enable --now ssh >/dev/null 2>&1; systemctl restart ssh

  # Suricata: Schnittstelle ens3, Regelpfad, eigene Regeldatei; HOME_NET bleibt Standard, keine Regeln
  Y=/etc/suricata/suricata.yaml
  cp -n $Y $Y.orig
  sed -i '0,/^  - interface: eth0/s//  - interface: ens3/' $Y
  sed -i 's|^default-rule-path:.*|default-rule-path: /var/lib/suricata/rules|' $Y
  awk 'BEGIN{skip=0} /^rule-files:/{print; print "  - suricata.rules"; print "  - /etc/suricata/rules/local.rules"; skip=1; next}
       skip==1 && /^ *- /{next} {skip=0; print}' $Y > /tmp/s.yaml && cat /tmp/s.yaml > $Y
  mkdir -p /etc/suricata/rules /var/lib/suricata/rules
  : > /etc/suricata/rules/local.rules
  rm -f /var/lib/suricata/rules/*.rules
  : > /var/lib/suricata/rules/suricata.rules
  systemctl enable suricata >/dev/null 2>&1; systemctl restart suricata
  ok "Suricata eingerichtet (ens3, ohne Regeln)"

  # Trivy aus dem Repository von Aqua Security, Datenbank vorladen
  wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor --yes -o /usr/share/keyrings/trivy.gpg
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" > /etc/apt/sources.list.d/trivy.list
  apt-get update -q && apt-get install -y -q trivy >/dev/null && ok "trivy installiert" || fail "trivy"
  trivy image --download-db-only -q && ok "Trivy-Datenbank vorgeladen" || fail "Trivy-Datenbank"

  # Shop-Stack laufen lassen
  if [ -f /opt/shop/compose.yaml ]; then (cd /opt/shop && docker compose up -d >/dev/null 2>&1); ok "Shop-Stack gestartet"; else fail "/opt/shop fehlt"; fi

  mkdir -p /home/gns3/lab; wget -q "$REPO/l17-verify.sh" -O /home/gns3/lab/l17-verify.sh; chown -R gns3:gns3 /home/gns3/lab
  cheatsheet gns3
  ;;
mon)
  echo "== SRV-MON =="
  apt-get update -q
  apt-get install -y -q ansible sshpass >/dev/null && ok "ansible, sshpass installiert" || fail "apt ansible"
  H=/home/gns3
  sudo -u gns3 bash -c "[ -f $H/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f $H/.ssh/id_ed25519"
  for T in 10.10.20.13 10.10.100.20; do
    sudo -u gns3 sshpass -p "$PW" ssh-copy-id -o StrictHostKeyChecking=accept-new -i $H/.ssh/id_ed25519.pub gns3@$T >/dev/null 2>&1 \
      && ok "SSH-Schluessel auf $T" || fail "SSH-Schluessel auf $T"
  done
  mkdir -p $H/ansible/group_vars
  cat > $H/ansible/ansible.cfg <<'C'
[defaults]
inventory = inventory.yml
host_key_checking = False
C
  cat > $H/ansible/inventory.yml <<'C'
---
all:
  children:
    linux:
      hosts:
        srv-web:
          ansible_host: 10.10.20.13
        srv-mon:
          ansible_host: 10.10.100.20
C
  cat > $H/ansible/group_vars/linux.yml <<'C'
---
ansible_user: gns3
ansible_become_password: Gns3456
C
  chown -R gns3:gns3 $H/ansible
  ok "Ansible-Projekt in ~/ansible"
  mkdir -p $H/lab; wget -q "$REPO/l17-verify.sh" -O $H/lab/l17-verify.sh; chown -R gns3:gns3 $H/lab
  cheatsheet gns3
  ;;
kali)
  echo "== KALI =="
  U=$(id -nu 1000 2>/dev/null || echo kali)
  echo "$U:$PW" | chpasswd && ok "Passwort fuer $U gesetzt"
  apt-get update -q
  apt-get install -y -q nmap sshpass curl >/dev/null && ok "nmap, sshpass, curl installiert" || fail "apt kali"
  cheatsheet "$U"
  ;;
*)
  echo "Aufruf: sudo bash l17.sh web | mon | kali"; exit 1;;
esac
echo "== fertig: $ROLE =="
