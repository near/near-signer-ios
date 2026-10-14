"""End-to-end tests: near-signer-host against near-signer-sim (the iOS app's signing core).

    swift build && python3 -m unittest discover -s host/python -v

Set NEAR_SIGNER_SIM to the simulator binary if it is not at .build/debug/near-signer-sim.
Fixtures come from near-api-js (see scripts/gen-fixtures.cjs).
"""

import base64
import contextlib
import hashlib
import io
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import near_signer_host as host  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SIM = os.environ.get("NEAR_SIGNER_SIM", os.path.join(ROOT, ".build", "debug", "near-signer-sim"))
with open(os.path.join(os.path.dirname(__file__), "test_fixtures.json")) as handle:
    FIXTURES = json.load(handle)

ed25519_verify = host.ed25519_verify


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def simulator(*args):
    port = free_port()
    process = subprocess.Popen([SIM, "--port", str(port), *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("simulator did not start")
        yield port
    finally:
        process.terminate()
        process.wait(5)
        process.stdout.close()


def run_cli(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = host.main(list(argv))
    return code, out.getvalue(), err.getvalue()


EXPECTED_KEY = host.b58decode(FIXTURES["publicKey"].split(":")[1])


@unittest.skipUnless(os.path.exists(SIM), f"build the simulator first ({SIM})")
class EndToEnd(unittest.TestCase):
    def assert_signed_transaction(self, result, fixture, name=None):
        unsigned = base64.b64decode(fixture["borsh"])
        signature = host.b58decode(result["signature"].split(":")[1])
        self.assertTrue(ed25519_verify(EXPECTED_KEY, hashlib.sha256(unsigned).digest(), signature), name)
        self.assertEqual(base64.b64decode(result["signedTransaction"]), unsigned + b"\x00" + signature, name)
        # swift-crypto on Linux (BoringSSL) signs deterministically, like tweetnacl, so the bytes
        # match near-api-js exactly. On macOS it uses CryptoKit, which randomizes ed25519 signatures.
        if sys.platform != "darwin":
            self.assertEqual(result["signedTransaction"], fixture["signed"], name)

    def test_public_key_and_version(self):
        with simulator("--auto-approve") as port:
            code, out, _ = run_cli("--tcp", f"127.0.0.1:{port}", "pubkey")
            self.assertEqual(code, 0)
            self.assertEqual(out.strip(), FIXTURES["publicKey"])
            code, out, _ = run_cli("--tcp", f"127.0.0.1:{port}", "version")
            self.assertEqual(out.strip(), "2.4.3")

    def test_sign_transactions_match_near_api_js(self):
        with simulator("--auto-approve") as port:
            for name in ("transfer", "functionCall", "deployContract"):
                fixture = FIXTURES[name]
                code, out, _ = run_cli("--tcp", f"127.0.0.1:{port}", "--json", "sign-tx", fixture["borsh"])
                self.assertEqual(code, 0, name)
                result = json.loads(out)
                self.assertEqual(result["transactionHash"], fixture["hash"])
                self.assert_signed_transaction(result, fixture, name)

    def test_near_cli_rs_display_output_and_json_file(self):
        fixture = FIXTURES["transfer"]
        display = (
            "\nTransaction hash to sign:\nabc.\n\nUnsigned transaction (serialized as base64):\n"
            f"{fixture['borsh']}\n\nThis base64-encoded transaction can be signed and sent later.\n"
        )
        self.assertEqual(host.extract_base64(display), fixture["borsh"])
        saved = json.dumps(
            {"Transaction hash to sign": "abc", "Unsigned transaction (serialized as base64)": fixture["borsh"]}
        )
        self.assertEqual(host.extract_base64(saved), fixture["borsh"])
        with (
            simulator("--auto-approve") as port,
            tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle,
        ):
            handle.write(saved)
            handle.flush()
            code, out, _ = run_cli("--tcp", f"127.0.0.1:{port}", "sign-tx", "--file", handle.name)
            self.assertEqual(code, 0)
            self.assertIn("near transaction send-signed-transaction", out)
            os.unlink(handle.name)

    def test_sign_message_and_delegate(self):
        with simulator("--auto-approve") as port:
            nonce = base64.b64encode(bytes(range(32))).decode()
            code, out, _ = run_cli(
                "--tcp",
                f"127.0.0.1:{port}",
                "sign-message",
                "--message",
                "hi",
                "--recipient",
                "app.near",
                "--nonce",
                nonce,
            )
            self.assertEqual(code, 0)
            result = json.loads(out)
            payload = host.nep413_payload("hi", "app.near", bytes(range(32)), None)
            digest = hashlib.sha256(host.NEP413_PREFIX + payload).digest()
            self.assertTrue(ed25519_verify(EXPECTED_KEY, digest, base64.b64decode(result["signature"])))

            code, out, _ = run_cli(
                "--tcp", f"127.0.0.1:{port}", "--json", "sign-delegate", FIXTURES["delegatePrefixed"]
            )
            self.assertEqual(code, 0)
            result = json.loads(out)
            prefixed = base64.b64decode(FIXTURES["delegatePrefixed"])
            signature = host.b58decode(result["signature"].split(":")[1])
            self.assertTrue(ed25519_verify(EXPECTED_KEY, hashlib.sha256(prefixed).digest(), signature))
            signed = base64.b64decode(result["signedDelegateAction"])
            self.assertEqual(signed, prefixed[4:] + b"\x00" + signature)

    def test_rejection_and_history(self):
        with tempfile.TemporaryDirectory() as directory:
            history = os.path.join(directory, "history.json")
            with simulator("--auto-reject", "--history", history) as port:
                code, _, err = run_cli("--tcp", f"127.0.0.1:{port}", "sign-tx", FIXTURES["transfer"]["borsh"])
                self.assertEqual(code, 1)
                self.assertIn("0x6985", err)
                code, _, err = run_cli(
                    "--tcp",
                    f"127.0.0.1:{port}",
                    "sign-tx",
                    base64.b64encode(b"\x01\x02 not a transaction " * 4).decode(),
                )
                self.assertEqual(code, 1)
                self.assertIn("0xb005", err)
            with open(history) as handle:
                records = json.load(handle)
            self.assertEqual([r["outcome"] for r in records], ["failed", "rejected"])
            self.assertEqual(records[1]["title"], "Send 1.5 NEAR to bob.testnet")
            listing = subprocess.run([SIM, "history", "--history", history], capture_output=True, text=True).stdout
            self.assertIn("rejected  Send 1.5 NEAR to bob.testnet", listing)

    def test_ble_packet_transport(self):
        with simulator("--auto-approve", "--ble-packets") as port:
            fixture = FIXTURES["deployContract"]
            code, out, _ = run_cli("--ble-over-tcp", f"127.0.0.1:{port}", "--json", "sign-tx", fixture["borsh"])
            self.assertEqual(code, 0)
            self.assert_signed_transaction(json.loads(out), fixture)

    def test_fast_mode_large_deploy(self):
        """A 128 KB deployment in 32 KiB extended APDUs, over TCP and over emulated BLE packets."""
        code = b"\0asm\x01\0\0\0" + bytes(range(256)) * 500
        unsigned = (
            host.borsh_string("alice.testnet")
            + b"\0"
            + EXPECTED_KEY
            + struct.pack("<Q", 7)
            + host.borsh_string("alice.testnet")
            + bytes(32)
            + struct.pack("<I", 1)
            + b"\x01"
            + struct.pack("<I", len(code))
            + code
        )
        digest = hashlib.sha256(unsigned).digest()
        for transport in ("--tcp", "--ble-over-tcp"):
            extra = ("--ble-packets",) if transport == "--ble-over-tcp" else ()
            for fast in (True, False):
                with (
                    simulator("--auto-approve", *extra) as port,
                    tempfile.NamedTemporaryFile("w", delete=False) as handle,
                ):
                    handle.write(base64.b64encode(unsigned).decode())
                    handle.flush()
                    flags = () if fast else ("--no-fast",)
                    code_, out, err = run_cli(
                        transport, f"127.0.0.1:{port}", *flags, "--json", "sign-tx", "--file", handle.name
                    )
                    os.unlink(handle.name)
                    self.assertEqual(code_, 0, err)
                    signature = host.b58decode(json.loads(out)["signature"].split(":")[1])
                    self.assertTrue(ed25519_verify(EXPECTED_KEY, digest, signature), (transport, fast))

    def test_fast_mode_uses_extended_apdus(self):
        """Counts what actually goes over the wire."""
        code = b"\0asm\x01\0\0\0" + bytes(100_000)
        unsigned = (
            host.borsh_string("alice.testnet")
            + b"\0"
            + EXPECTED_KEY
            + struct.pack("<Q", 7)
            + host.borsh_string("alice.testnet")
            + bytes(32)
            + struct.pack("<I", 1)
            + b"\x01"
            + struct.pack("<I", len(code))
            + code
        )
        for fast in (True, False):
            with simulator("--auto-approve") as port:
                transport = host.TcpTransport("127.0.0.1", port)
                sizes = []
                exchange = transport.exchange
                transport.exchange = lambda command, sizes=sizes, exchange=exchange: (
                    sizes.append(len(command)) or exchange(command)
                )
                signature = host.NearSigner(transport, fast=fast).sign_transaction(unsigned)
                transport.close()
                self.assertTrue(ed25519_verify(EXPECTED_KEY, hashlib.sha256(unsigned).digest(), signature))
                sign_sizes = sizes[1:] if fast else sizes
                if fast:
                    self.assertGreater(max(sign_sizes), 260)
                    self.assertLessEqual(len(sign_sizes), 5)
                else:
                    self.assertLessEqual(max(sign_sizes), 255 + 5)

    def test_capabilities_reported(self):
        with simulator("--auto-approve") as port:
            code, out, err = run_cli("--tcp", f"127.0.0.1:{port}", "version")
            self.assertEqual(code, 0)
            self.assertEqual(out.strip(), "2.4.3")
            self.assertIn("fast mode: chunks of up to 32768 bytes", err)


class Units(unittest.TestCase):
    def test_ble_write_plan(self):
        self.assertEqual(host.ble_write_plan(3, 500, True), [True] * 3)  # short: every packet acknowledged
        self.assertEqual(host.ble_write_plan(10, 5000, False), [True] * 10)  # a Ledger: no write-without-response
        plan = host.ble_write_plan(10, 5000, True)
        self.assertEqual(plan, [False, False, False, True, False, False, False, True, False, True])

    def test_bad_signature_is_not_printed(self):
        class Liar:
            """Answers every APDU, but returns a signature that doesn't match."""

            def exchange(self, command):
                if command[1] == host.INS_GET_CAPABILITIES:
                    return b"\x6d\x00"
                return (bytes(64) if command[2] == host.P1_LAST else b"") + b"\x90\x00"

            def close(self):
                pass

        fixture = FIXTURES["transfer"]
        original = host.open_transport
        host.open_transport = lambda args: Liar()
        try:
            code, out, err = run_cli("sign-tx", fixture["borsh"])
            delegate_code, delegate_out, delegate_err = run_cli("sign-delegate", FIXTURES["delegatePrefixed"])
        finally:
            host.open_transport = original
        self.assertEqual(code, 1)
        self.assertIn("does not verify", err)
        self.assertNotIn("Signature", out)
        self.assertEqual(delegate_code, 1)
        self.assertIn("does not verify", delegate_err)
        self.assertNotIn("Signature", delegate_out)
        self.assertEqual(host.delegate_public_key(base64.b64decode(FIXTURES["delegatePrefixed"])[4:]), EXPECTED_KEY)

    def test_extended_apdu_and_ledger_fallback(self):
        self.assertEqual(host.apdu(0x02, 0x80, 0x57, b"x" * 255)[:5], bytes([0x80, 0x02, 0x80, 0x57, 255]))
        self.assertEqual(host.apdu(0x02, 0x80, 0x57, b"x" * 300)[:7], bytes([0x80, 0x02, 0x80, 0x57, 0, 0x01, 0x2C]))

        class Ledger:
            """Answers like a Ledger: 6D00 for the capability command, OK otherwise."""

            def __init__(self):
                self.sent = []

            def exchange(self, command):
                self.sent.append(command)
                if command[1] == host.INS_GET_CAPABILITIES:
                    return b"\x6d\x00"
                return (bytes(64) if command[2] == host.P1_LAST else b"") + b"\x90\x00"

        ledger = Ledger()
        host.NearSigner(ledger).sign_transaction(bytes(1000))
        sign_commands = [c for c in ledger.sent if c[1] == host.INS_SIGN_TRANSACTION]
        self.assertEqual(len(sign_commands), 5)  # 1020 bytes in 250-byte short APDUs
        self.assertTrue(all(len(c) <= 255 + 5 for c in sign_commands))

    def test_path_and_base58(self):
        self.assertEqual(host.parse_path("m/44'/397'/0'/0'/1'").hex(), "8000002c8000018d800000008000000080000001")
        with self.assertRaises(ValueError):
            host.parse_path("44'/397'/0'")
        for data in (b"", b"\0\0\1", os.urandom(32)):
            self.assertEqual(host.b58decode(host.b58encode(data)), data)

    def test_ble_framing(self):
        for mtu in (20, 156):
            for size in (3, 15, 16, 400):
                message = os.urandom(size)
                framing = host.LedgerBleFraming()
                frames = host.LedgerBleFraming.frames(message, mtu)
                self.assertTrue(all(len(f) <= mtu for f in frames))
                results = [framing.feed(f) for f in frames]
                self.assertEqual(results[-1], message)
                self.assertTrue(all(r is None for r in results[:-1]))


if __name__ == "__main__":
    unittest.main()
