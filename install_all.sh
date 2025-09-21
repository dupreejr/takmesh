#!/bin/bash
set -e

USER="joseph"
HOME_DIR="/home/$USER"
OTS_DIR="$HOME_DIR/OpenTAKServer"
VENV_DIR="$OTS_DIR/venv_ots"
MENU_SCRIPT="$HOME_DIR/control_menu.sh"
SERVICE_OTS="opentakserver.service"

echo "[*] Installing dependencies..."
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git \
    postgresql postgresql-contrib libssl-dev

# --- Database setup (lightweight for Pi Zero 2W) ---
echo "[*] Configuring PostgreSQL..."
sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'otsuser') THEN
      CREATE USER otsuser WITH PASSWORD 'ots_password';
   END IF;
END
\$do\$;

CREATE DATABASE otsdb OWNER otsuser;
EOF

# --- Clone OTS repo ---
if [ ! -d "$OTS_DIR" ]; then
    echo "[*] Cloning OpenTAKServer..."
    git clone https://github.com/brian7704/OpenTAKServer.git "$OTS_DIR"
fi

# --- Python venv for OTS ---
echo "[*] Creating venv for OpenTAKServer..."
python3 -m venv "$VENV_DIR"
. "$VENV_DIR/bin/activate"
pip install --upgrade pip setuptools wheel
pip install OpenTAKServer
deactivate

# --- Minimal config file if missing ---
if [ ! -f "$OTS_DIR/config.yml" ]; then
    echo "[*] Creating basic config.yml..."
    cat > "$OTS_DIR/config.yml" <<EOL
server:
  ip: 0.0.0.0
  port: 8089
database:
  user: otsuser
  password: ots_password
  host: localhost
  name: otsdb
EOL
fi

# --- Systemd service for OpenTAKServer ---
echo "[*] Creating systemd service..."
sudo tee /etc/systemd/system/$SERVICE_OTS > /dev/null <<EOL
[Unit]
Description=OpenTAKServer
After=network.target postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$OTS_DIR
ExecStart=$VENV_DIR/bin/opentakserver --config $OTS_DIR/config.yml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_OTS

# --- Update control_menu.sh ---
echo "[*] Updating control_menu.sh to include OpenTAKServer..."

if ! grep -q "OpenTAKServer" "$MENU_SCRIPT"; then
    sed -i '/Reticulum:/a OpenTAK:   $(status_dot opentakserver.service) ($(systemctl is-active opentakserver.service 2>/dev/null))' "$MENU_SCRIPT"

    # Add options
    sed -i '/14) Exit/i\    echo "15) Start OpenTAKServer"\n    echo "16) Stop OpenTAKServer"\n    echo "17) View OpenTAKServer Logs"' "$MENU_SCRIPT"

    # Add case block
    sed -i '/14) exit 0 ;;/i\
        15) sudo systemctl start opentakserver.service ;;\n\
        16) sudo systemctl stop opentakserver.service ;;\n\
        17)\n\
            journalctl -u opentakserver.service -n 20\n\
            echo\n\
            echo "=== Live OpenTAKServer logs (Ctrl+C to stop) ==="\n\
            journalctl -u opentakserver.service -f\n\
            read -p "Press Enter to return to menu..." dummy\n\
        ;;' "$MENU_SCRIPT"
fi

echo "[✓] OpenTAKServer installed and control_menu.sh updated."
echo "Start with: sudo systemctl start opentakserver.service"
echo "Access in menu: ./control_menu.sh"
