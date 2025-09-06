#!/usr/bin/env python3
"""
TAK <-> Meshtastic Bridge v2
- TAK CoT XML → Meshtastic synthetic nodes (NodeInfo + Position + Chat)
- Meshtastic protobuf → CoT XML (positions + chat)
- Synthetic node IDs stable per TAK callsign
- Filters: only export nodes seen in last 3h
- CoT stale-time: 5 minutes (symbols don't disappear immediately)
- Debug logging to ~/takmesh2.log
"""

import socket, meshtastic, meshtastic.serial_interface
import signal, sys, time, uuid, logging, struct, hashlib, datetime
import xml.etree.ElementTree as ET
from xml.etree.ElementTree import Element, tostring
from logging.handlers import RotatingFileHandler
from meshtastic import mesh_pb2

# === CONFIG ===
SERIAL_PORT   = "/dev/ttyUSB0"
CHANNEL_INDEX = 2
TAK_IP        = "239.2.3.1"
TAK_PORT      = 6969
LOGFILE       = "/home/joseph/takmesh2.log"
MESH_DUMP_INTERVAL = 60    # seconds
COT_STALE_MINUTES = 5      # CoT validity
MESH_MAX_AGE_SEC  = 3*3600 # only nodes seen in last 3h

radio = None
tak_sock = None
cot_listener = None

# --- Logging setup ---
logger = logging.getLogger("takmesh2")
logger.setLevel(logging.DEBUG)

console = logging.StreamHandler(sys.stdout)
console.setLevel(logging.INFO)
console.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(console)

file_handler = RotatingFileHandler(LOGFILE, maxBytes=1_000_000, backupCount=5)
file_handler.setLevel(logging.DEBUG)
file_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(file_handler)

# --- Graceful shutdown ---
def shutdown(sig, frame):
    logger.info("Shutting down TAK <-> Meshtastic bridge...")
    if radio:
        try: radio.close()
        except: pass
    if tak_sock: tak_sock.close()
    if cot_listener: cot_listener.close()
    sys.exit(0)

signal.signal(signal.SIGINT, shutdown)
signal.signal(signal.SIGTERM, shutdown)

# --- UDP sockets ---
def setup_udp():
    global tak_sock, cot_listener
    tak_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    tak_sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)

    cot_listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    cot_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    cot_listener.bind(("", TAK_PORT))

    mreq = struct.pack("=4sl", socket.inet_aton(TAK_IP), socket.INADDR_ANY)
    cot_listener.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

    logger.info(f"Listening for CoT on {TAK_IP}:{TAK_PORT} (multicast + unicast)")

# --- Utility: safe callsign lookup ---
def get_node_callsign(node, node_id):
    try:
        if isinstance(node, dict) and "user" in node:
            u = node["user"]
            if isinstance(u, dict) and "name" in u:
                return u["name"]
            if hasattr(u, "name") and getattr(u, "name"):
                return u.name
        if hasattr(node, "user"):  # protobuf NodeInfo
            u = node.user
            if hasattr(u, "name") and getattr(u, "name"):
                return u.name
    except Exception as e:
        logger.debug(f"callsign lookup failed for node {node_id}: {e}")
    return str(node_id)

# --- Utility: time stamps for CoT ---
def cot_time_offsets(minutes_valid=COT_STALE_MINUTES):
    now = datetime.datetime.utcnow()
    stale = now + datetime.timedelta(minutes=minutes_valid)
    return (
        now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        stale.strftime("%Y-%m-%dT%H:%M:%SZ")
    )

# --- Synthetic node ID ---
def callsign_to_nodeid(callsign: str) -> int:
    return int(hashlib.sha256(callsign.encode()).hexdigest(), 16) & 0xFFFFFFFF

# --- Inject synthetic node into Meshtastic ---
def send_virtual_position(radio, callsign, lat, lon):
    node_id = callsign_to_nodeid(callsign)

    # Wrap NodeInfo
    nodeinfo = mesh_pb2.NodeInfo()
    nodeinfo.num = node_id
    nodeinfo.user.id = str(node_id)
    nodeinfo.user.name = callsign
    nodeinfo.user.hwModel = "TAK-Bridge"

    pkt_node = mesh_pb2.Data()
    pkt_node.portnum = mesh_pb2.PortNum.NODEINFO_APP
    pkt_node.payload = nodeinfo.SerializeToString()

    radio._sendPacket(
        toId=0xFFFFFFFF,
        channelIndex=CHANNEL_INDEX,
        payload=pkt_node.SerializeToString(),
        portnum=mesh_pb2.PortNum.NODEINFO_APP
    )

    # Wrap Position
    pos = mesh_pb2.Position()
    pos.latitude = lat
    pos.longitude = lon
    pos.time = int(time.time())

    pkt_pos = mesh_pb2.Data()
    pkt_pos.portnum = mesh_pb2.PortNum.POSITION_APP
    pkt_pos.payload = pos.SerializeToString()

    radio._sendPacket(
        toId=0xFFFFFFFF,
        channelIndex=CHANNEL_INDEX,
        payload=pkt_pos.SerializeToString(),
        portnum=mesh_pb2.PortNum.POSITION_APP
    )

    logger.info(f"Injected synthetic node {callsign} (0x{node_id:08X}) @ {lat},{lon}")

# --- Inject TAK chat into Meshtastic ---
def send_virtual_chat(radio, callsign, msg):
    node_id = callsign_to_nodeid(callsign)

    # Ensure NodeInfo exists
    nodeinfo = mesh_pb2.NodeInfo()
    nodeinfo.num = node_id
    nodeinfo.user.id = str(node_id)
    nodeinfo.user.name = callsign
    nodeinfo.user.hwModel = "TAK-Bridge"

    pkt_node = mesh_pb2.Data()
    pkt_node.portnum = mesh_pb2.PortNum.NODEINFO_APP
    pkt_node.payload = nodeinfo.SerializeToString()

    radio._sendPacket(
        toId=0xFFFFFFFF,
        channelIndex=CHANNEL_INDEX,
        payload=pkt_node.SerializeToString(),
        portnum=mesh_pb2.PortNum.NODEINFO_APP
    )

    # Send chat
    pkt = mesh_pb2.Data()
    pkt.portnum = mesh_pb2.PortNum.TEXT_MESSAGE_APP
    pkt.payload = msg.encode("utf-8")

    radio._sendPacket(
        toId=0xFFFFFFFF,
        channelIndex=CHANNEL_INDEX,
        payload=pkt.SerializeToString(),
        portnum=mesh_pb2.PortNum.TEXT_MESSAGE_APP
    )

    logger.info(f"Injected TAK chat as synthetic node {callsign}: {msg}")

# --- TAK → Meshtastic ---
def cot_to_meshtastic(cot_xml, radio):
    try:
        root = ET.fromstring(cot_xml)
        cot_type = root.attrib.get("type", "")

        if cot_type.startswith("a-"):  # Position
            point = root.find("point")
            contact = root.find("detail/contact")
            if point is not None:
                lat = float(point.attrib["lat"])
                lon = float(point.attrib["lon"])
                callsign = contact.attrib.get("callsign", "Unknown") if contact is not None else "Unknown"
                send_virtual_position(radio, callsign, lat, lon)

        elif cot_type == "b-t-f":  # Chat
            chat = root.find("detail/chat")
            contact = root.find("detail/contact")
            if chat is not None:
                msg = chat.attrib.get("msg", "")
                callsign = contact.attrib.get("callsign", "Unknown") if contact is not None else "Unknown"
                send_virtual_chat(radio, callsign, msg)

    except Exception as e:
        logger.error(f"CoT parse error: {e}")

# --- NodeInfo → CoT (for mesh dump) ---
def nodeinfo_to_cot(node_id, node):
    name = get_node_callsign(node, node_id)
    event = Element("event", {
        "version": "2.0",
        "type": "a-u-G-U-C",
        "uid": f"Meshtastic-{node_id}",
        "how": "m-g"
    })
    t, s = cot_time_offsets()
    event.set("time", t)
    event.set("start", t)
    event.set("stale", s)

    if "position" in node:
        pos = node["position"]
        point = Element("point", {
            "lat": str(pos.get("latitude", 0)),
            "lon": str(pos.get("longitude", 0)),
            "hae": "0", "ce": "9999999", "le": "9999999"
        })
        event.append(point)

    detail = Element("detail")
    contact = Element("contact", {"callsign": name})
    detail.append(contact)

    if "deviceMetrics" in node:
        metrics = node["deviceMetrics"]
        status = Element("status", {
            "battery": str(metrics.get("batteryLevel", "")),
            "voltage": str(metrics.get("voltage", ""))
        })
        detail.append(status)

    event.append(detail)
    return tostring(event)

# --- Meshtastic → TAK ---
def meshtastic_to_cot(packet, interface):
    try:
        if packet["decoded"]["portnum"] == "POSITION_APP":
            pos = packet["decoded"]["position"]
            node_id = packet["fromId"]
            node = interface.nodes.get(node_id, {})
            name = get_node_callsign(node, node_id)

            event = Element("event", {
                "version": "2.0",
                "type": "a-u-G-U-C",
                "uid": f"Meshtastic-{node_id}",
                "how": "m-g"
            })
            t, s = cot_time_offsets()
            event.set("time", t)
            event.set("start", t)
            event.set("stale", s)

            point = Element("point", {
                "lat": str(pos["latitude"]),
                "lon": str(pos["longitude"]),
                "hae": "0", "ce": "9999999", "le": "9999999"
            })
            event.append(point)

            detail = Element("detail")
            contact = Element("contact", {"callsign": name})
            detail.append(contact)
            event.append(detail)

            cot_xml = tostring(event)
            tak_sock.sendto(cot_xml, (TAK_IP, TAK_PORT))
            logger.info(f"Forwarded Meshtastic position → TAK ({name} @ {pos['latitude']},{pos['longitude']})")

        elif packet["decoded"]["portnum"] == "TEXT_MESSAGE_APP":
            node_id = packet["fromId"]
            msg = packet["decoded"]["text"]
            node = interface.nodes.get(node_id, {})
            name = get_node_callsign(node, node_id)

            event = Element("event", {
                "version": "2.0",
                "type": "b-t-f",
                "uid": f"Meshtastic-{node_id}-{uuid.uuid4()}",
                "how": "m-g"
            })
            t, s = cot_time_offsets()
            event.set("time", t)
            event.set("start", t)
            event.set("stale", s)

            detail = Element("detail")
            contact = Element("contact", {"callsign": name})
            chat = Element("chat", {
                "msg": msg,
                "chatroom": "All Chat Rooms",
                "parent": "RootContactGroup",
                "groupOwner": "false"
            })
            detail.append(contact)
            detail.append(chat)
            event.append(detail)

            cot_xml = tostring(event)
            tak_sock.sendto(cot_xml, (TAK_IP, TAK_PORT))
            logger.info(f"Forwarded Meshtastic chat → TAK ({name}: {msg})")

    except Exception as e:
        logger.error(f"Meshtastic → CoT conversion error: {e}")

# --- MAIN ---
def main():
    global radio
    setup_udp()

    logger.info("Starting TAK <-> Meshtastic bridge v2 (with proper position injection)...")
    radio = meshtastic.serial_interface.SerialInterface(SERIAL_PORT)
    radio.onReceive = meshtastic_to_cot

    try:
        radio.sendText("bridge-up", channelIndex=CHANNEL_INDEX)
        logger.info("Sent 'bridge-up' over Meshtastic")
    except Exception as e:
        logger.error(f"Bridge-up send failed: {e}")

    last_dump = 0

    while True:
        data, addr = cot_listener.recvfrom(65535)
        cot = data.decode("utf-8", errors="ignore").strip()
        if cot:
            cot_to_meshtastic(cot, radio)

        now = time.time()
        if now - last_dump > MESH_DUMP_INTERVAL:
            cutoff = now - MESH_MAX_AGE_SEC
            for node_id, node in radio.nodes.items():
                last_heard = None
                if isinstance(node, dict):
                    last_heard = node.get("lastHeard")
                elif hasattr(node, "lastHeard"):
                    last_heard = getattr(node, "lastHeard")

                if last_heard and last_heard < cutoff:
                    continue

                cot_xml = nodeinfo_to_cot(node_id, node)
                tak_sock.sendto(cot_xml, (TAK_IP, TAK_PORT))
                logger.info(f"Broadcast mesh node {node_id} ({get_node_callsign(node, node_id)}) → TAK")
            last_dump = now

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logger.exception(f"Fatal error in takmesh2: {e}")
        sys.exit(1)
