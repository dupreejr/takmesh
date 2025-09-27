#!/bin/bash
set -e
set -x   # verbose

echo "=== Meshtastic Menu + Python Chat Installer ==="

echo "[1/6] Installing prerequisites..."
sudo apt update
sudo apt install -y python3-venv python3-pip

echo "[2/6] Creating Python virtual environment in ~/meshtastic-venv..."
if [ ! -d "$HOME/meshtastic-venv" ]; then
    python3 -m venv ~/meshtastic-venv
fi

echo "[3/6] Installing Meshtastic Python library into venv..."
source ~/meshtastic-venv/bin/activate
pip install --upgrade pip
pip install meshtastic pubsub pyserial
deactivate

echo "[4/6] Creating menu directory ~/mesh_menu..."
mkdir -p ~/mesh_menu

echo "[5/6] Writing menu script to ~/mesh_menu/mesh_menu.py..."
cat > ~/mesh_menu/mesh_menu.py <<'EOF'
#!/usr/bin/env python3
import os
import subprocess
import glob
import meshtastic.serial_interface
import pubsub.pub

# --- Config ---
VENV_PATH = os.path.expanduser("~/meshtastic-venv")
MESHTASTIC = os.path.join(VENV_PATH, "bin", "meshtastic")

def run_cmd(cmd):
    """Run Meshtastic CLI command"""
    full_cmd = [MESHTASTIC] + cmd
    try:
        subprocess.run(full_cmd, check=True)
    except Exception as e:
        print(f"[!] Error running: {' '.join(full_cmd)}")
        print(e)

def find_serial_port():
    """Auto-detect serial port for radio"""
    ports = glob.glob("/dev/ttyUSB*") + glob.glob("/dev/serial/by-id/*")
    if not ports:
        print("[!] No Meshtastic device found. Plug in your radio.")
        return None
    print(f"[*] Using serial port: {ports[0]}")
    return ports[0]

def start_chat():
    """Start Python-based terminal chat"""
    port = find_serial_port()
    if not port:
        return
    iface = meshtastic.serial_interface.SerialInterface(port)

    def on_receive(packet, interface):
        try:
            if packet.get("decoded", {}).get("portnum") == "TEXT_MESSAGE_APP":
                sender = packet.get("fromId", "Unknown")
                msg = packet["decoded"].get("text", "")
                print(f"\n[{sender}] {msg}\n> ", end="")
        except Exception as e:
            print(f"[!] Error decoding packet: {e}")

    pubsub.pub.subscribe(on_receive, "meshtastic.receive")

    print("[*] Meshtastic Python Chat started")
    print("Type messages and press Enter to send. Ctrl+C to quit.")
    try:
        while True:
            msg = input("> ")
            if msg.strip():
                iface.sendText(msg)
    except KeyboardInterrupt:
        print("\n[*] Chat ended.")

def menu():
    while True:
        print("\n--- Meshtastic Menu ---")
        print("1. Get radio info")
        print("2. Change setting")
        print("3. Terminal chat (Python)")
        print("4. Quick send message")
        print("5. Exit")

        choice = input("Select an option: ").strip()

        if choice == "1":
            run_cmd(["--info"])

        elif choice == "2":
            setting = input("Enter setting (example: device.role=router): ").strip()
            if "=" in setting:
                run_cmd(["--set", setting])
            else:
                print("[!] Invalid format.")

        elif choice == "3":
            start_chat()

        elif choice == "4":
            msg = input("Message: ").strip()
            if msg:
                run_cmd(["--sendtext", msg])

        elif choice == "5":
            print("Exiting.")
            break

        else:
            print("[!] Invalid option.")

if __name__ == "__main__":
    if not os.path.exists(MESHTASTIC):
        print(f"[!] Could not find meshtastic CLI at {MESHTASTIC}")
        print("    Run: source ~/meshtastic-venv/bin/activate && pip install meshtastic")
        exit(1)
    menu()
EOF

chmod +x ~/mesh_menu/mesh_menu.py

echo "[6/6] Adding ~/mesh_menu to PATH if missing..."
if ! grep -q 'export PATH=$HOME/mesh_menu:$PATH' ~/.bashrc; then
    echo 'export PATH=$HOME/mesh_menu:$PATH' >> ~/.bashrc
    echo "[*] Added ~/mesh_menu to PATH. Run 'source ~/.bashrc' or restart your terminal."
else
    echo "[*] ~/mesh_menu already in PATH."
fi

echo "=== Installation complete ==="
echo "Run the menu with: mesh_menu.py"
