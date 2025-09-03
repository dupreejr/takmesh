#!/usr/bin/env python3
"""
TAK <-> Meshtastic Bridge
- Runs on Raspberry Pi with Meshtastic node over USB
- Forwards TAK CoT chat + position events over LoRa (channel 3)
- Reassembles chunks on the other side and multicasts back into TAK
"""

import socket, meshtastic, meshtastic.serial_interface
import signal, sys, json, time, uuid, logging
import xml.etree.ElementTree as ET

# === CONFIG ===
SERIAL_PORT = "/dev/ttyUSB0"     # Meshtastic USB device
CHANNEL_INDEX = 2                # Channel 3 (zero-based index)
TAK_IP = "239.2.3.1"             # TAK multicast
TAK_PORT = 6969                  # TAK UDP port
MAX_CHUNK = 180                  # safe LoRa payload size
CHUNK_DELAY = 0.5                # throttle to avoid flooding LoRa

buffers = {}                     # msgid -> {parts, total, ts}
radio = None
tak_sock = None
cot_listener = None

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")

# --- Shutdown handler ---
def shutdown(sig, frame):
    logging.info("Shutting down TAK <-> Meshtastic bridge...")
    if radio: 
        try: radio.close()
        except: pass
    if tak_sock: tak_sock.close()
    if cot_listener: cot_listener.close()
    sys.exit(0)

signal.signal(signal.SIGINT, shutdown)
signal.signal(signal.SIGTERM, shutdown)

# --- UDP sockets ---
tak_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
tak_sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)

cot_listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
cot_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
cot_listener.bind(("", TAK_PORT))

# --- Chunk helpers ---
def chunk_message(data: str, max_size=MAX_CHUNK):
    """Split message into chunks with msgid metadata."""
    msgid = str(uuid.uuid4())
    parts = [data[i:i+max_size] for i in range(0, len(data), max_size)]
    for idx, part in enumerate(parts):
        wrapper = {"msgid": msgid, "part": idx, "total": len(parts), "data": part}
        yield json.dumps(wrapper)
    return

def reassemble(packet_text):
    """Reassemble chunked messages."""
    try:
        payload = json.loads(packet_text)
        msgid = payload["msgid"]
        if msgid not in buffers:
            buffers[msgid] = {"parts": {}, "total": payload["total"], "ts": time.time()}
        buffers[msgid]["parts"][payload["part"]] = payload["data"]

        if len(buffers[msgid]["parts"]) == buffers[msgid]["total"]:
            msg = "".join(buffers[msgid]["parts"][i] for i in range(payload["total"]))
            del buffers[msgid]
            return msg
    except Exception as e:
        logging.error(f"Reassembly error: {e}")
    return None

# --- Filter TAK CoT messages ---
def is_allowed_cot(cot_xml: str) -> bool:
    """Allow only CoT type a-* (positions) or b-t-f (chat)."""
    try:
        root = ET.fromstring(cot_xml)
        cot_type = root.attrib.get("type", "")
        if cot_type.startswith("a-"):   # positions
            return True
        if cot_type == "b-t-f":         # chat
            return True
    except Exception as e:
        logging.warning(f"Invalid CoT XML: {e}")
    return False

# --- Meshtastic receive handler ---
def on_meshtastic(packet, interface):
    if packet["decoded"]["portnum"] == "TEXT_MESSAGE_APP":
        full = reassemble(packet["decoded"]["text"])
        if full:
            logging.info("Reassembled CoT from radio → TAK")
            tak_sock.sendto(full.encode("utf-8"), (TAK_IP, TAK_PORT))

# --- MAIN LOOP ---
def main():
    global radio
    logging.info("Starting TAK <-> Meshtastic bridge on channel 3 (chat + position only)...")
    radio = meshtastic.serial_interface.SerialInterface(SERIAL_PORT)
    radio.onReceive = on_meshtastic

    while True:
        data, addr = cot_listener.recvfrom(65535)
        cot = data.decode("utf-8", errors="ignore").strip()
        if cot:
            logging.debug(f"Got CoT XML: {cot[:150]}...")
            if is_allowed_cot(cot):
                logging.info("Forwarding allowed CoT from TAK → Meshtastic")
                for chunk in chunk_message(cot):
                    radio.sendText(chunk, channelIndex=CHANNEL_INDEX)
                    time.sleep(CHUNK_DELAY)
            else:
                logging.debug("Dropped non-position/chat CoT event")

if __name__ == "__main__":
    main()
