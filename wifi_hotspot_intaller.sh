#!/bin/bash
set -e

MENU_SCRIPT="/home/joseph/hotspot_menu.sh"
SSID="tak21"
PASS="Skyf@ll121"
IFACE="wlan0"
HOTSPOT_IP="192.168.50.1"

echo "[*] Installing hotspot packages..."
sudo apt update
sudo apt install -y hostapd dnsmasq net-tools

echo "[*] Stopping services if running..."
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true
sudo systemctl disable hostapd || true
sudo systemctl disable dnsmasq || true

echo "[*] Creating hotspot config..."
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOL
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOL

sudo sed -i "s|#DAEMON_CONF=\"\"|DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"|" /etc/default/hostapd

[ ! -f /etc/dnsmasq.conf.orig ] && sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
sudo tee /etc/dnsmasq.conf > /dev/null <<EOL
interface=$IFACE
bind-interfaces
server=8.8.8.8
dhcp-range=192.168.50.10,192.168.50.50,255.255.255.0,24h
EOL

echo "[*] Creating hotspot control menu..."
cat > "$MENU_SCRIPT" <<EOF
#!/bin/bash

SSID="$SSID"
PASS="$PASS"
IFACE="$IFACE"
HOTSPOT_IP="$HOTSPOT_IP"

while true; do
  clear
  echo "===== Hotspot Menu ====="
  echo "SSID: \$SSID"
  echo "PASS: \$PASS"
  echo
  echo "1) Start Hotspot"
  echo "2) Stop Hotspot (return to Wi-Fi)"
  echo "3) Show Hotspot Info"
  echo "4) Exit"
  read -p "Select an option: " choice

  case \$choice in
    1)
      echo "[*] Starting hotspot..."
      sudo systemctl stop NetworkManager || true
      sudo ifconfig \$IFACE \$HOTSPOT_IP netmask 255.255.255.0 up
      sudo systemctl start dnsmasq
      sudo systemctl start hostapd
      echo "[✓] Hotspot started (SSID=\$SSID)"
      read -p "Press Enter to continue..."
      ;;
    2)
      echo "[*] Stopping hotspot and restoring Wi-Fi..."
      sudo systemctl stop hostapd
      sudo systemctl stop dnsmasq
      sudo systemctl start NetworkManager || true
      echo "[✓] Wi-Fi mode restored."
      read -p "Press Enter to continue..."
      ;;
    3)
      echo "Hotspot SSID: \$SSID"
      echo "Hotspot PASS: \$PASS"
      echo "Interface: \$IFACE"
      echo "Static IP: \$HOTSPOT_IP"
      read -p "Press Enter to continue..."
      ;;
    4) exit 0 ;;
  esac
done
EOF

chmod +x "$MENU_SCRIPT"

echo "[✓] Hotspot menu installed."
echo "Run it with: $MENU_SCRIPT"
