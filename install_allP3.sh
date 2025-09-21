#!/bin/bash
set -e

USER="joseph"
HOME_DIR="/home/$USER"

APP_DIR="$HOME_DIR/TAK_Meshtastic_Gateway"
VENV_DIR="$APP_DIR/venv_takmesh"
BRIDGE_SCRIPT="$HOME_DIR/takmesh2.py"
MENU_SCRIPT="$HOME_DIR/control_menu.sh"

echo "[*] Cleaning old installs..."
sudo systemctl stop takmesh.service || true
sudo systemctl stop takmesh2.service || true
sudo systemctl stop reticulum.service || true
rm -rf "$APP_DIR" "$BRIDGE_SCRIPT" "$MENU_SCRIPT" "$HOME_DIR/takmesh2.log"
sudo rm -f /etc/systemd/system/takmesh.service
sudo rm -f /etc/systemd/system/takmesh2.service
sudo rm -f /etc/systemd/system/reticulum.service
sudo rm -f /etc/systemd/system/opentakserver.service

# --- Update & deps ---
echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
    python3 python3-venv python3-pip git build-essential \
    libgpiod-dev libyaml-cpp-dev libbluetooth-dev \
    libffi-dev libssl-dev python3-dev pkg-config \
    hostapd dnsmasq net-tools

# --- Clone TAK_Meshtastic_Gateway ---
echo "[*] Cloning TAK_Meshtastic_Gateway..."
git clone https://github.com/brian7704/TAK_Meshtastic_Gateway.git "$APP_DIR"

# --- Create venv ---
echo "[*] Creating Python venv..."
python3 -m venv "$VENV_DIR"
. "$VENV_DIR/bin/activate"

# --- Install Python deps ---
echo "[*] Installing Python dependencies..."
pip install --upgrade pip setuptools wheel
pip install --upgrade --force-reinstall --no-cache-dir pyopenssl cryptography
pip install --force-reinstall --no-cache-dir git+https://github.com/snstac/takproto.git@main
pip install --upgrade --force-reinstall --no-cache-dir tak-meshtastic-gateway meshtastic protobuf
deactivate

# --- Deploy takmesh2.py ---
cat > "$BRIDGE_SCRIPT" <<'EOF'
#!/usr/bin/env python3
# (your final takmesh2.py goes here — with heartbeat, CAE marker, stats)
EOF
chmod +x "$BRIDGE_SCRIPT"

# --- Deploy control_menu.sh ---
cat > "$MENU_SCRIPT" <<'EOF'
#!/bin/bash

SERVICE_GATEWAY="takmesh.service"
SERVICE_BRIDGE="takmesh2.service"
SERVICE_RETICULUM="reticulum.service"
BRIDGE_LOG="/home/joseph/takmesh2.log"
HOTSPOT_SSID="tak21"
HOTSPOT_PASS="Skyf@ll121"

GREEN="\e[32m●\e[0m"
RED="\e[31m●\e[0m"
GREY="\e[90m●\e[0m"

status_dot() {
    if systemctl is-active --quiet "$1"; then
        echo -e "$GREEN"
    else
        echo -e "$RED"
    fi
}

while true; do
    clear
    echo "===== Control Menu ====="
    echo "Gateway:   $(status_dot $SERVICE_GATEWAY) ($(systemctl is-active $SERVICE_GATEWAY 2>/dev/null))"
    echo "Bridge:    $(status_dot $SERVICE_BRIDGE) ($(systemctl is-active $SERVICE_BRIDGE 2>/dev/null))"
    echo "Reticulum: $(status_dot $SERVICE_RETICULUM) ($(systemctl is-active $SERVICE_RETICULUM 2>/dev/null))"
    echo "OpenTAK:   $GREY (Not available on Pi Zero / Python <3.10)"
    echo "Hotspot:   $(systemctl is-active hostapd) (SSID=$HOTSPOT_SSID, PASS=$HOTSPOT_PASS)"
    echo
    echo "1) Start Gateway"
    echo "2) Stop Gateway"
    echo "3) View Gateway Logs (filtered)"
    echo "4) Start Bridge"
    echo "5) Stop Bridge"
    echo "6) View Bridge Logs"
    echo "7) Show Bridge Stats"
    echo "8) Start Reticulum"
    echo "9) Stop Reticulum"
    echo "10) View Reticulum Logs"
    echo "11) Meshtastic CLI Submenu"
    echo "12) Hotspot Menu"
    echo "13) Refresh Status (auto 2s)"
    echo "14) Exit"
    read -p "Select an option: " choice

    case $choice in
        1) sudo systemctl start $SERVICE_GATEWAY ;;
        2) sudo systemctl stop $SERVICE_GATEWAY ;;
        3) 
            journalctl -u $SERVICE_GATEWAY -n 20 | grep -v "timed out"
            echo
            echo "=== Live Gateway logs (Ctrl+C to stop) ==="
            journalctl -u $SERVICE_GATEWAY -f | grep -v "timed out"
            read -p "Press Enter to return to menu..." dummy
        ;;
        4) sudo systemctl start $SERVICE_BRIDGE ;;
        5) sudo systemctl stop $SERVICE_BRIDGE ;;
        6) 
            journalctl -u $SERVICE_BRIDGE -n 20
            echo
            echo "=== Live Bridge logs (Ctrl+C to stop) ==="
            journalctl -u $SERVICE_BRIDGE -f
            read -p "Press Enter to return to menu..." dummy
        ;;
        7) 
            echo "--- Bridge Stats (last 20 lines) ---"
            tail -n 20 "$BRIDGE_LOG"
            echo
            echo "=== Live Bridge stats (Ctrl+C to stop) ==="
            tail -f "$BRIDGE_LOG"
            read -p "Press Enter to return to menu..." dummy
        ;;
        8) sudo systemctl start $SERVICE_RETICULUM ;;
        9) sudo systemctl stop $SERVICE_RETICULUM ;;
        10) 
            journalctl -u $SERVICE_RETICULUM -n 20
            echo
            echo "=== Live Reticulum logs (Ctrl+C to stop) ==="
            journalctl -u $SERVICE_RETICULUM -f
            read -p "Press Enter to return to menu..." dummy
        ;;
        11)
            while true; do
                echo "--- Meshtastic CLI ---"
                echo "1) Send message"
                echo "2) Show radio info"
                echo "3) Monitor packets"
                echo "4) Back"
                read -p "Choice: " cli
                case $cli in
                    1) read -p "Enter message: " msg; meshtastic --sendtext "$msg" ;;
                    2) meshtastic --info ;;
                    3) meshtastic --monitor ;;
                    4) break ;;
                esac
            done
        ;;
        12)
            while true; do
                echo "--- Hotspot Menu ---"
                echo "1) Start Hotspot"
                echo "2) Stop Hotspot"
                echo "3) Restart Hotspot"
                echo "4) Show SSID/Password"
                echo "5) Back"
                read -p "Choice: " h
                case $h in
                    1) sudo systemctl start hostapd dnsmasq ;;
                    2) sudo systemctl stop hostapd dnsmasq ;;
                    3) sudo systemctl restart hostapd dnsmasq ;;
                    4) echo "SSID=$HOTSPOT_SSID PASS=$HOTSPOT_PASS"; read -p "Enter to continue..." ;;
                    5) break ;;
                esac
            done
        ;;
        13)
            while true; do
                clear
                echo "===== Auto-Refresh ====="
                echo "Gateway:   $(status_dot $SERVICE_GATEWAY) ($(systemctl is-active $SERVICE_GATEWAY 2>/dev/null))"
                echo "Bridge:    $(status_dot $SERVICE_BRIDGE) ($(systemctl is-active $SERVICE_BRIDGE 2>/dev/null))"
                echo "Reticulum: $(status_dot $SERVICE_RETICULUM) ($(systemctl is-active $SERVICE_RETICULUM 2>/dev/null))"
                echo "OpenTAK:   $GREY (Not available)"
                echo "Hotspot:   $(systemctl is-active hostapd) (SSID=$HOTSPOT_SSID)"
                echo "Press Ctrl+C to exit refresh"
                sleep 2
            done
        ;;
        14) exit 0 ;;
    esac
done
EOF
chmod +x "$MENU_SCRIPT"

# --- Systemd services ---
sudo tee /etc/systemd/system/takmesh.service > /dev/null <<EOL
[Unit]
Description=TAK Meshtastic Gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/tak-meshtastic-gateway --serial-device /dev/ttyUSB0 -p 4243 -c 0.0.0.0 -d
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

sudo tee /etc/systemd/system/takmesh2.service > /dev/null <<EOL
[Unit]
Description=TAK <-> Meshtastic Bridge (takmesh2.py)
After=network.target

[Service]
Type=simple
WorkingDirectory=$HOME_DIR
ExecStart=$VENV_DIR/bin/python $BRIDGE_SCRIPT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

# --- Reticulum install LAST ---
echo "[*] Installing Reticulum..."
if sudo pip install --upgrade rns; then
    sudo tee /etc/systemd/system/reticulum.service > /dev/null <<EOL
[Unit]
Description=Reticulum Networking Stack
After=network.target

[Service]
ExecStart=/usr/local/bin/rnsd
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
    sudo systemctl enable reticulum.service
else
    echo "[!] Reticulum failed to install. Everything else is ready."
fi

# --- Enable services ---
sudo systemctl daemon-reload
sudo systemctl enable takmesh.service takmesh2.service

echo "[✓] Installation complete!"
echo "Run the control menu with: $MENU_SCRIPT"
