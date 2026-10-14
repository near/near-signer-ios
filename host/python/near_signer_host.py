#!/usr/bin/env python3
"""near-signer-host: talk to the NEAR Signer iPhone app (or near-signer-sim) from a computer.

Transports
  --tcp HOST:PORT   Speculos APDU framing. Use it for
                      * the iOS Simulator (Simulator builds listen on 127.0.0.1:9999 of the Mac),
                      * near-signer-sim.
  --ble             Bluetooth LE, Ledger Nano X profile (needs `pip install bleak`). Use it for
                    a real iPhone.
  --ble-over-tcp HOST:PORT
                    Raw Ledger BLE packets over TCP (near-signer-sim --ble-packets), for tests.

Typical flow with near-cli-rs (any version, no Ledger feature needed):
  near tokens alice.testnet send-near bob.testnet '0.1 NEAR' network-config testnet \
      sign-later --signer-public-key ed25519:... --nonce N --block-hash HASH display
  near-signer-host sign-tx <base64 from "Unsigned transaction (serialized as base64)">
  near transaction send-signed-transaction '<signed base64>' network-config testnet send

Only the Python standard library is required.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import re
import socket
import struct
import sys

CLA = 0x80
INS_SIGN_TRANSACTION = 0x02
INS_GET_PUBLIC_KEY = 0x04
INS_GET_VERSION = 0x06
INS_SIGN_NEP413 = 0x07
INS_SIGN_NEP366 = 0x08
INS_GET_CAPABILITIES = 0x20  # NEAR Signer only; a Ledger answers 0x6D00
P1_MORE = 0x00
P1_LAST = 0x80
NETWORK_ID = ord("W")
CHUNK_SIZE = 250
# Long messages (fast mode) go without a response per BLE packet, except every BLE_ACK_EVERY-th
# packet and the last one. Several OS Bluetooth stacks (CoreBluetooth on macOS among them) drop
# unacknowledged writes when their queue is full; a short interval keeps it from filling.
BLE_ACK_EVERY = 4
BLE_LONG_MESSAGE = 1024


def ble_write_plan(packet_count: int, message_length: int, without_response_allowed: bool) -> list[bool]:
    """For each packet, whether to write it with a response."""
    if message_length <= BLE_LONG_MESSAGE or not without_response_allowed:
        return [True] * packet_count
    return [index == packet_count - 1 or index % BLE_ACK_EVERY == BLE_ACK_EVERY - 1 for index in range(packet_count)]


DEFAULT_PATH = "44'/397'/0'/0'/1'"
NEP366_PREFIX = struct.pack("<I", (1 << 30) + 366)
NEP413_PREFIX = struct.pack("<I", (1 << 31) + 413)

LEDGER_SERVICE = "13d63400-2c97-0004-0000-4c6564676572"
LEDGER_NOTIFY = "13d63400-2c97-0004-0001-4c6564676572"
LEDGER_WRITE = "13d63400-2c97-0004-0002-4c6564676572"

STATUS_WORDS = {
    0x6985: "rejected on the device",
    0x6A80: "invalid data",
    0x6A86: "wrong P1/P2",
    0x6D00: "instruction not supported",
    0x6E00: "class not supported",
    0x5515: "signer locked or no key configured",
    0xB005: "the device could not decode the payload and refused to sign it",
    0xB00B: "unsupported derivation path (5 hardened levels required)",
    0xB00D: "the transaction's public key does not match the device key at this path",
    0x6601: "the device is busy with another request",
}

BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# ---------------------------------------------------------------------------
# Minimal RFC 8032 ed25519 verification (public data only, so constant time is not needed).
# The host checks every signature the device returns before printing it.
# ---------------------------------------------------------------------------
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
I = pow(2, (P - 1) // 4, P)  # noqa: E741 (sqrt(-1) mod P, as RFC 8032 names it)


def _recover_x(y, sign):
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * I % P
    if (x * x - x2) % P:
        return None
    if x & 1 != sign:
        x = P - x
    return x


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A = (y1 - x1) * (y2 - x2) % P
    B = (y1 + x1) * (y2 + x2) % P
    C = 2 * t1 * t2 * D % P
    Dd = 2 * z1 * z2 % P
    E, F, G, H = B - A, Dd - C, Dd + C, B + A
    return (E * F % P, G * H % P, F * G % P, E * H % P)


def _mul(s, point):
    result = (0, 1, 1, 0)
    while s:
        if s & 1:
            result = _add(result, point)
        point = _add(point, point)
        s >>= 1
    return result


def _decode(data):
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


GY = 4 * pow(5, P - 2, P) % P
G = (_recover_x(GY, 0), GY, 1, _recover_x(GY, 0) * GY % P)


def ed25519_verify(public_key: bytes, message: bytes, signature: bytes) -> bool:
    A = _decode(public_key)
    R = _decode(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if A is None or R is None or s >= L:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public_key + message).digest(), "little") % L
    return _equal(_mul(s, G), _add(R, _mul(h, A)))


def transaction_public_key(unsigned: bytes) -> bytes | None:
    """The ed25519 key a borsh Transaction (V0 or V1) names, or None for another key type."""
    offset = 1 if len(unsigned) > 1 and unsigned[0] == 1 and unsigned[1] != 0 else 0
    (length,) = struct.unpack_from("<I", unsigned, offset)
    offset += 4 + length
    if unsigned[offset] != 0:
        return None
    return unsigned[offset + 1 : offset + 33]


def delegate_public_key(delegate: bytes) -> bytes | None:
    """The ed25519 key a borsh DelegateAction names (its last field), or None for another key type."""
    if len(delegate) < 33 or delegate[-33] != 0:
        return None
    return delegate[-32:]


class DeviceError(Exception):
    def __init__(self, status: int):
        self.status = status
        super().__init__(f"device returned 0x{status:04x}: {STATUS_WORDS.get(status, 'unknown error')}")


def b58encode(data: bytes) -> str:
    value = int.from_bytes(data, "big")
    out = ""
    while value:
        value, rem = divmod(value, 58)
        out = BASE58_ALPHABET[rem] + out
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + out


def b58decode(text: str) -> bytes:
    value = 0
    for char in text:
        value = value * 58 + BASE58_ALPHABET.index(char)
    body = value.to_bytes((value.bit_length() + 7) // 8, "big") if value else b""
    return b"\0" * (len(text) - len(text.lstrip("1"))) + body


def parse_path(path: str) -> bytes:
    parts = [p for p in path.strip().split("/") if p and p != "m"]
    if len(parts) != 5:
        raise ValueError("the NEAR Ledger protocol needs exactly 5 path levels, e.g. 44'/397'/0'/0'/1'")
    out = b""
    for part in parts:
        hardened = part.endswith(("'", "h", "H"))
        index = int(part.rstrip("'hH"))
        out += struct.pack(">I", index | 0x80000000 if hardened else index)
    return out


def apdu(ins: int, p1: int, p2: int, data: bytes = b"") -> bytes:
    """Short APDU, or extended (00 Lc_hi Lc_lo) above 255 bytes: only for NEAR Signer fast mode."""
    if len(data) <= 255:
        return bytes([CLA, ins, p1, p2, len(data)]) + data
    if len(data) > 0xFFFF - 7:
        raise ValueError("APDU data too long")
    return bytes([CLA, ins, p1, p2, 0]) + struct.pack(">H", len(data)) + data


class Capabilities:
    """NEAR Signer's answer to 80 20: "NS", version, flags, largest chunk (u32 BE)."""

    def __init__(self, data: bytes):
        if len(data) < 8 or data[:2] != b"NS":
            raise ValueError("not a NEAR Signer capability answer")
        self.version, self.flags = data[2], data[3]
        self.max_chunk = struct.unpack(">I", data[4:8])[0]

    @property
    def extended_apdu(self) -> bool:
        return bool(self.flags & 0x01)


# ---------------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------------


class TcpTransport:
    """Speculos framing: request u32 BE length + APDU; response u32 BE length (without SW) + data + SW."""

    def __init__(self, host: str, port: int, timeout: float = 600.0):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(timeout)

    def _read(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise ConnectionError("device closed the connection")
            data += chunk
        return data

    def exchange(self, command: bytes) -> bytes:
        self.sock.sendall(struct.pack(">I", len(command)) + command)
        length = struct.unpack(">I", self._read(4))[0]
        return self._read(length + 2)

    def close(self) -> None:
        self.sock.close()


class LedgerBleFraming:
    """Ledger BLE framing: 0x05 | seq u16 BE | [total length u16 BE on seq 0] | data."""

    @staticmethod
    def frames(message: bytes, mtu: int) -> list[bytes]:
        frames, offset, seq = [], 0, 0
        while True:
            header = bytes([0x05]) + struct.pack(">H", seq)
            if seq == 0:
                header += struct.pack(">H", len(message))
            take = mtu - len(header)
            frames.append(header + message[offset : offset + take])
            offset += take
            seq += 1
            if offset >= len(message):
                return frames

    def __init__(self):
        self.buffer = b""
        self.expected = None
        self.next_seq = 0

    def feed(self, packet: bytes) -> bytes | None:
        if len(packet) < 3 or (packet[1:3] == b"\0\0" and len(packet) < 5):
            raise ValueError("BLE packet too short")
        if packet[0] != 0x05:
            raise ValueError(f"unexpected BLE tag 0x{packet[0]:02x}")
        seq = struct.unpack(">H", packet[1:3])[0]
        if seq != self.next_seq:
            raise ValueError(f"unexpected BLE sequence {seq}")
        if seq == 0:
            self.expected = struct.unpack(">H", packet[3:5])[0]
            self.buffer = packet[5:]
        else:
            self.buffer += packet[3:]
        self.next_seq += 1
        if len(self.buffer) >= self.expected:
            message = self.buffer[: self.expected]
            self.buffer, self.expected, self.next_seq = b"", None, 0
            return message
        return None


class BlePacketsOverTcpTransport:
    """Raw Ledger BLE packets over TCP (u16 BE length per packet), as served by near-signer-sim --ble-packets."""

    def __init__(self, host: str, port: int):
        self.tcp = socket.create_connection((host, port), timeout=600)
        self.mtu = 20
        self.write(bytes([0x08, 0, 0, 0, 0]))
        reply = self.read_packet()
        if reply[0] == 0x08 and len(reply) > 5 and reply[5] > 5:
            self.mtu = reply[5]

    def write(self, packet: bytes) -> None:
        self.tcp.sendall(struct.pack(">H", len(packet)) + packet)

    def read_packet(self) -> bytes:
        header = self._read(2)
        return self._read(struct.unpack(">H", header)[0])

    def _read(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self.tcp.recv(count - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    def exchange(self, command: bytes) -> bytes:
        for frame in LedgerBleFraming.frames(command, self.mtu):
            self.write(frame)
        framing = LedgerBleFraming()
        while True:
            message = framing.feed(self.read_packet())
            if message is not None:
                return message

    def close(self) -> None:
        self.tcp.close()


class BleTransport:
    """Bluetooth LE via bleak (pip install bleak). Finds the phone by Ledger's Nano X service UUID."""

    def __init__(self, name: str | None = None, timeout: float = 600.0):
        try:
            import bleak  # noqa: F401
        except ImportError as error:
            raise SystemExit("Bluetooth needs bleak: pip install bleak") from error
        self.loop = asyncio.new_event_loop()
        self.timeout = timeout
        self.loop.run_until_complete(self._connect(name))

    async def _connect(self, name: str | None) -> None:
        from bleak import BleakClient, BleakScanner

        def match(device, advertisement):
            uuids = [u.lower() for u in advertisement.service_uuids]
            return LEDGER_SERVICE in uuids and (name is None or (advertisement.local_name or device.name) == name)

        device = await BleakScanner.find_device_by_filter(match, timeout=15.0)
        if device is None:
            raise SystemExit("no NEAR Signer found: open the app on the iPhone and keep it in the foreground")
        self.client = BleakClient(device)
        await self.client.connect()
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()
        await self.client.start_notify(LEDGER_NOTIFY, lambda _c, data: self.queue.put_nowait(bytes(data)))
        await self.client.write_gatt_char(LEDGER_WRITE, bytes([0x08, 0, 0, 0, 0]), response=True)
        reply = await asyncio.wait_for(self.queue.get(), 10)
        self.mtu = reply[5] if reply[0] == 0x08 and len(reply) > 5 and reply[5] > 5 else 20
        properties = self.client.services.get_characteristic(LEDGER_WRITE).properties
        self.without_response_allowed = "write-without-response" in properties

    async def _exchange(self, command: bytes) -> bytes:
        # A reply that arrived after an earlier timeout must not be taken as this one's answer.
        while not self.queue.empty():
            self.queue.get_nowait()
        frames = LedgerBleFraming.frames(command, self.mtu)
        # Only long (fast-mode) messages, and only if the characteristic allows it (a Ledger's
        # does not), skip the response per packet.
        plan = ble_write_plan(len(frames), len(command), self.without_response_allowed)
        for frame, wait in zip(frames, plan):
            await self.client.write_gatt_char(LEDGER_WRITE, frame, response=wait)
        framing = LedgerBleFraming()
        while True:
            message = framing.feed(await asyncio.wait_for(self.queue.get(), self.timeout))
            if message is not None:
                return message

    def exchange(self, command: bytes) -> bytes:
        return self.loop.run_until_complete(self._exchange(command))

    def close(self) -> None:
        self.loop.run_until_complete(self.client.disconnect())


# ---------------------------------------------------------------------------
# NEAR Ledger app client
# ---------------------------------------------------------------------------


class NearSigner:
    def __init__(self, transport, fast: bool = True):
        self.transport = transport
        self.fast = fast
        self._chunk_size: int | None = None

    def send(self, command: bytes) -> bytes:
        response = self.transport.exchange(command)
        status = int.from_bytes(response[-2:], "big")
        if status != 0x9000:
            raise DeviceError(status)
        return response[:-2]

    def capabilities(self) -> Capabilities | None:
        """NEAR Signer's fast-mode capabilities, or None for a Ledger (0x6D00) or any odd answer:
        the probe must never stop a signing that would work with standard chunks."""
        try:
            return Capabilities(self.send(apdu(INS_GET_CAPABILITIES, 0, 0)))
        except Exception:  # noqa: BLE001 - any failure means "no fast mode"
            return None

    def chunk_size(self) -> int:
        if self._chunk_size is None:
            capabilities = self.capabilities() if self.fast else None
            if capabilities and capabilities.extended_apdu and capabilities.max_chunk > CHUNK_SIZE:
                self._chunk_size = min(capabilities.max_chunk, 0xFFFF - 7)
            else:
                self._chunk_size = CHUNK_SIZE
        return self._chunk_size

    def version(self) -> str:
        return ".".join(str(b) for b in self.send(apdu(INS_GET_VERSION, 0, 0)))

    def public_key(self, path: str = DEFAULT_PATH, display: bool = False) -> bytes:
        return self.send(apdu(INS_GET_PUBLIC_KEY, 0 if display else 1, NETWORK_ID, parse_path(path)))

    def _sign(self, ins: int, payload: bytes, path: str) -> bytes:
        data = parse_path(path) + payload
        size = self.chunk_size()
        chunks = [data[i : i + size] for i in range(0, len(data), size)]
        result = b""
        for index, chunk in enumerate(chunks):
            last = index == len(chunks) - 1
            result = self.send(apdu(ins, P1_LAST if last else P1_MORE, NETWORK_ID, chunk))
        if len(result) != 64:
            raise ValueError(f"unexpected signature length {len(result)}")
        return result

    def sign_transaction(self, unsigned: bytes, path: str = DEFAULT_PATH) -> bytes:
        return self._sign(INS_SIGN_TRANSACTION, unsigned, path)

    def sign_delegate_action(self, delegate: bytes, path: str = DEFAULT_PATH) -> bytes:
        if delegate.startswith(NEP366_PREFIX):
            delegate = delegate[4:]
        return self._sign(INS_SIGN_NEP366, delegate, path)

    def sign_message(self, payload: bytes, path: str = DEFAULT_PATH) -> bytes:
        if payload.startswith(NEP413_PREFIX):
            payload = payload[4:]
        return self._sign(INS_SIGN_NEP413, payload, path)


def borsh_string(value: str) -> bytes:
    raw = value.encode()
    return struct.pack("<I", len(raw)) + raw


def nep413_payload(message: str, recipient: str, nonce: bytes, callback_url: str | None) -> bytes:
    if len(nonce) != 32:
        raise ValueError("NEP-413 nonce must be 32 bytes")
    out = borsh_string(message) + nonce + borsh_string(recipient)
    out += b"\x01" + borsh_string(callback_url) if callback_url else b"\x00"
    return out


def extract_base64(text: str) -> str:
    """Accepts plain base64, near-cli-rs `display` output, or its `save-to-file` JSON."""
    text = text.strip()
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            for key, value in data.items():
                if "Unsigned transaction" in key or "base64" in key.lower():
                    return str(value)
    except ValueError:
        pass
    candidates = re.findall(r"[A-Za-z0-9+/]{40,}={0,2}", text)
    if not candidates:
        raise ValueError("no base64 transaction found in input")
    return max(candidates, key=len)


def read_input(value: str | None, file: str | None) -> str:
    if file:
        with open(file, encoding="utf-8") as handle:
            return handle.read()
    if value in (None, "-"):
        return sys.stdin.read()
    return value


def open_transport(args):
    if args.ble:
        return BleTransport(args.ble_name)
    if args.ble_over_tcp:
        host, port = args.ble_over_tcp.rsplit(":", 1)
        return BlePacketsOverTcpTransport(host, int(port))
    host, port = args.tcp.rsplit(":", 1)
    return TcpTransport(host, int(port))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="near-signer-host", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--tcp", default=os.environ.get("NEAR_SIGNER_TCP", "127.0.0.1:9999"))
    parser.add_argument("--ble", action="store_true", help="use Bluetooth LE (needs bleak)")
    parser.add_argument("--ble-name", help="only connect to a device advertising this name")
    parser.add_argument("--ble-over-tcp", metavar="HOST:PORT", help=argparse.SUPPRESS)
    parser.add_argument("--path", default=DEFAULT_PATH, help=f"derivation path (default {DEFAULT_PATH})")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument(
        "--no-fast", action="store_true", help="use 250-byte chunks even if the device offers NEAR Signer fast mode"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("version", help="NEAR app version reported by the device")
    pubkey = sub.add_parser("pubkey", help="get the public key")
    pubkey.add_argument("--display", action="store_true", help="ask the user to confirm on the phone")
    tx = sub.add_parser("sign-tx", help="sign a base64 borsh Transaction (near-cli-rs sign-later output)")
    tx.add_argument("transaction", nargs="?", help="base64, or '-' for stdin")
    tx.add_argument("--file", help="file with the base64 or near-cli-rs save-to-file JSON")
    tx.add_argument("--network", default="testnet", help="network for the printed near-cli-rs command")
    delegate = sub.add_parser("sign-delegate", help="sign a base64 borsh DelegateAction (NEP-366)")
    delegate.add_argument("delegate", nargs="?", help="base64, or '-' for stdin")
    delegate.add_argument("--file")
    message = sub.add_parser("sign-message", help="sign a NEP-413 message")
    message.add_argument("--message", required=True)
    message.add_argument("--recipient", required=True)
    message.add_argument("--nonce", help="32-byte nonce, base64 (random if omitted)")
    message.add_argument("--callback-url")
    args = parser.parse_args(argv)

    transport = open_transport(args)
    signer = NearSigner(transport, fast=not args.no_fast)
    try:
        if args.command == "version":
            print(signer.version())
            capabilities = signer.capabilities()
            if capabilities and capabilities.extended_apdu:
                print(f"NEAR Signer fast mode: chunks of up to {capabilities.max_chunk} bytes", file=sys.stderr)
        elif args.command == "pubkey":
            key = signer.public_key(args.path, args.display)
            print("ed25519:" + b58encode(key))
        elif args.command == "sign-tx":
            unsigned = base64.b64decode(extract_base64(read_input(args.transaction, args.file)))
            signature = signer.sign_transaction(unsigned, args.path)
            public_key = transaction_public_key(unsigned)
            if public_key is None:
                print(
                    "error: the transaction names a key that is not ed25519, which the device cannot sign for",
                    file=sys.stderr,
                )
                return 1
            if not ed25519_verify(public_key, hashlib.sha256(unsigned).digest(), signature):
                print("error: the signature does not verify against the transaction's public key", file=sys.stderr)
                return 1
            signed = unsigned + b"\x00" + signature
            result = {
                "transactionHash": b58encode(hashlib.sha256(unsigned).digest()),
                "signature": "ed25519:" + b58encode(signature),
                "signedTransaction": base64.b64encode(signed).decode(),
            }
            if args.json:
                print(json.dumps(result, indent=2))
            else:
                print(f"Transaction hash: {result['transactionHash']}")
                print(f"Signature:        {result['signature']}")
                print(f"\nSigned transaction (base64):\n{result['signedTransaction']}")
                print("\nBroadcast with near-cli-rs:")
                print(
                    f"  near transaction send-signed-transaction '{result['signedTransaction']}' "
                    f"network-config {args.network} send"
                )
        elif args.command == "sign-delegate":
            raw = base64.b64decode(extract_base64(read_input(args.delegate, args.file)))
            if raw.startswith(NEP366_PREFIX):
                raw = raw[4:]
            signature = signer.sign_delegate_action(raw, args.path)
            public_key = delegate_public_key(raw)
            if public_key is None:
                print(
                    "error: the delegate action names a key that is not ed25519, which the device cannot sign for",
                    file=sys.stderr,
                )
                return 1
            if not ed25519_verify(public_key, hashlib.sha256(NEP366_PREFIX + raw).digest(), signature):
                print("error: the signature does not verify against the delegate action's public key", file=sys.stderr)
                return 1
            signed = raw + b"\x00" + signature
            result = {
                "signature": "ed25519:" + b58encode(signature),
                "signedDelegateAction": base64.b64encode(signed).decode(),
            }
            print(
                json.dumps(result, indent=2)
                if args.json
                else f"Signature: {result['signature']}\nSigned delegate action (base64):\n{result['signedDelegateAction']}"
            )
        elif args.command == "sign-message":
            nonce = base64.b64decode(args.nonce) if args.nonce else os.urandom(32)
            payload = nep413_payload(args.message, args.recipient, nonce, args.callback_url)
            signature = signer.sign_message(payload, args.path)
            public_key = signer.public_key(args.path)
            if not ed25519_verify(public_key, hashlib.sha256(NEP413_PREFIX + payload).digest(), signature):
                print("error: the signature does not verify against the device's public key", file=sys.stderr)
                return 1
            result = {
                "publicKey": "ed25519:" + b58encode(public_key),
                "signature": base64.b64encode(signature).decode(),
                "nonce": base64.b64encode(nonce).decode(),
                "recipient": args.recipient,
                "message": args.message,
            }
            print(json.dumps(result, indent=2))
    except DeviceError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        transport.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
