#!/bin/bash
# ==============================================
# SETUP BRIDGE RADXA - VERSIONE STABILE
# ==============================================

set -euo pipefail

echo "=== Setup Bridge su Radxa ==="

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "Questo script deve essere eseguito come root (usa sudo)"
    exit 1
fi

# 1. Installazione pacchetti necessari
echo "Installazione pacchetti necessari..."
apt update
apt install -y netplan.io iptables-persistent bridge-utils

# 2. Backup della configurazione netplan esistente
echo "Backup configurazione netplan..."
mkdir -p /etc/netplan/backup
cp -r /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true

echo "=== Configurazione Bridge br0 con MAC fisso ==="


echo "=== Configurazione Bridge br0 con MAC fisso da eth0 ==="

# Recupera automaticamente il MAC address di eth0
ETH0_MAC=$(ip -o link show eth0 | awk '{print $17}' | tr -d '"')

if [[ -z "$ETH0_MAC" ]]; then
    echo "Impossibile leggere MAC di eth0. Verrà usato un MAC generato."
    ETH0_MAC=""
else
    echo "MAC di eth0 rilevato: $ETH0_MAC → verrà usato per br0"
fi

# Creazione file Netplan
cat > /etc/netplan/01-bridge.yaml <<EOF
network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      dhcp4: no
      optional: true
    enp1s0:
      dhcp4: no
      optional: true

  bridges:
    br0:
      dhcp4: yes
      macaddress: ${ETH0_MAC}
      interfaces:
        - eth0
        - enp1s0
      parameters:
        stp: false
        forward-delay: 0
EOF

echo "Netplan configurato con MAC fisso da eth0"

# 4. Configurazione sysctl (IP forwarding + Proxy ARP)
echo "Configurazione sysctl (IP forwarding + Proxy ARP)..."

# Creiamo il file di configurazione persistente
cat > /etc/sysctl.d/99-bridge.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.proxy_arp = 1
net.ipv4.conf.default.proxy_arp = 1
net.ipv4.conf.br0.proxy_arp = 1
EOF

# Carichiamo i moduli kernel necessari
modprobe bridge 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

# Applichiamo i parametri generali
sysctl -p /etc/sysctl.d/99-bridge.conf >/dev/null 2>&1 || true

# Aspettiamo che netplan crei il bridge
echo "Aspetto creazione interfaccia br0..."
sleep 4

# Applichiamo proxy_arp specificamente su br0
if [ -d "/proc/sys/net/ipv4/conf/br0" ]; then
    sysctl -w net.ipv4.conf.br0.proxy_arp=1 >/dev/null
    echo "Proxy ARP abilitato su br0"
else
    echo "br0 non ancora pronto. Proxy ARP su br0 sarà abilitato al prossimo riavvio."
fi

# 5. Configurazione iptables permanente
echo "Configurazione regole iptables..."
iptables -A FORWARD -i br0 -j ACCEPT
iptables -A FORWARD -o br0 -j ACCEPT

# Salva le regole iptables in modo permanente
netfilter-persistent save

# 6. Applica Netplan
echo "Applicazione configurazione Netplan aspettare riavvio della macchina e guardare mail per sapere nuovo indirizzo IP!"
netplan generate
netplan apply

# 7. Riavvio servizi
echo "Riavvio NetworkManager e systemd-networkd..."
systemctl restart systemd-networkd
systemctl restart NetworkManager

sleep 15
sudo reboot

