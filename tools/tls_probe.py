#!/usr/bin/env python3
"""Disposable mutual-TLS harness. Synthetic hello frames only; not product pairing.

prepare: generate short-lived credentials under ignored .tooling and test assets.
serve: bind loopback only; adb reverse exposes it to the connected development phone.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".tooling" / "tls-probe"
ASSETS = ROOT / "apps/android/app/build/generated/probeAssets"
MAX_FRAME = 512 * 1024


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    ASSETS.mkdir(parents=True, exist_ok=True)
    os.chmod(WORK, 0o700)
    openssl = shutil.which("openssl")
    if not openssl:
        raise SystemExit("OpenSSL is required")

    def run(*args):
        subprocess.run([openssl, *args], cwd=WORK, check=True, capture_output=True)

    run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
        "-keyout", "ca.key", "-out", "ca.crt", "-subj", "/CN=Companion disposable probe CA")
    for name, purpose in (("server", "serverAuth"), ("client", "clientAuth")):
        common_name = "localhost" if name == "server" else "Companion probe client"
        run("req", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{name}.key",
            "-out", f"{name}.csr", "-subj", f"/CN={common_name}")
        extensions = f"basicConstraints=CA:FALSE\nextendedKeyUsage={purpose}\n"
        if name == "server":
            extensions += "subjectAltName=DNS:localhost,IP:127.0.0.1\n"
        (WORK / f"{name}.ext").write_text(extensions)
        run("x509", "-req", "-in", f"{name}.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
            "-CAcreateserial", "-out", f"{name}.crt", "-days", "2",
            "-extfile", f"{name}.ext")
    run("pkcs12", "-export", "-inkey", "client.key", "-in", "client.crt",
        "-certfile", "ca.crt", "-out", str(ASSETS / "client.p12"),
        "-passout", "pass:probe-only")
    shutil.copyfile(WORK / "ca.crt", ASSETS / "ca.crt")
    for key in WORK.glob("*.key"):
        key.chmod(0o600)
    print("Prepared disposable credentials for test APK only.")


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise EOFError("Peer disconnected before complete frame")
        result.extend(part)
    return bytes(result)


def serve():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(WORK / "server.crt", WORK / "server.key")
    context.load_verify_locations(WORK / "ca.crt")
    context.verify_mode = ssl.CERT_REQUIRED
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 18443))
        listener.listen(1)
        listener.settimeout(180)
        print("Probe ready on loopback:18443; client certificate required.", flush=True)
        raw, _ = listener.accept()
        raw.settimeout(15)
        with context.wrap_socket(raw, server_side=True) as stream:
            header = read_exact(stream, 4)
            length = struct.unpack(">I", header)[0]
            if not 1 <= length <= MAX_FRAME:
                raise ValueError("Invalid frame length")
            payload = read_exact(stream, length)
            expected = json.loads((ROOT / "protocol/fixtures/hello.json").read_bytes())
            if json.loads(payload) != expected:
                raise ValueError("Probe accepts only the synthetic fixture")
            stream.sendall(header + payload)
            print(f"PASS: verified client certificate and echoed synthetic hello over {stream.version()}.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "serve"])
    args = parser.parse_args()
    prepare() if args.command == "prepare" else serve()
