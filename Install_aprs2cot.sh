#!/bin/bash
set -e

echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[*] Installing dependencies..."
sudo apt install -y python3 python3-pip git

echo "[*] Installing Python libraries..."
pip3 install aprslib

echo "[*] Creating aprs2cot directory..."
mkdir -p ~/aprs2cot
cd ~/aprs2cot

echo "[*] Writing aprs2cot_test.py script..."
cat << 'EOF' > aprs2cot_test.py
import socket
import aprslib
import datetime

# ==== SETTINGS ====
APRS_SERVER = "rotate.aprs2.net"
APRS_PORT = 14580
APRS_FILTER = "r/33.9388/-81.1195/24"   # ~15mi radius around CAE airport
APRS_CALLSIGN = "N0CALL-10"             # Replace with your callsign-SSID

TAK_HOST = "127.0.0.1"   # ATAK device IP or TAK Server IP
TAK_PORT = 8087          # Default CoT port
# ===================

def packet_to_cot(pkt):
    lat = pkt.get("latitude")
    lon = pkt.get("longitude")
    if lat is None or lon is None:
        return None

    now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
    stale = (datetime.datetime.utcnow() + datetime.timedelta(minutes=5)).replace(microsecond=0).isoformat() + "Z"
    callsign = pkt.get("from", "APRS")

    cot = f"""<event version="2.0" uid="APRS-{callsign}" type="a-f-G-U-C" how="m-g"
  time="{now}" start="{now}" stale="{stale}">
  <point lat="{lat}" lon="{lon}" hae="0" ce="9999999" le="9999999"/>
  <detail>
    <contact callsign="{callsign}"/>
    <remarks>{pkt.get("comment", "APRS Packet")}</remarks>
  </detail>
</event>"""
    return cot

def send_to_tak(cot_xml):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.sendto(cot_xml.encode("utf-8"), (TAK_HOST, TAK_PORT))

def main():
    ais = aprslib.IS(APRS_CALLSIGN, host=APRS_SERVER, port=APRS_PORT, aprs_filter=APRS_FILTER)
    ais.connect()
    ais.consumer(lambda pkt: (
        send_to_tak(xml) if (xml := packet_to_cot(pkt)) else None
    ), raw=False)

if __name__ == "__main__":
    main()
EOF

echo "[*] Install complete!"
echo "---------------------------------------------------"
echo "Your script is at: ~/aprs2cot/aprs2cot_test.py"
echo "Edit APRS_CALLSIGN before running!"
echo
echo "Run it with:"
echo "    python3 ~/aprs2cot/aprs2cot_test.py"
echo "---------------------------------------------------"
