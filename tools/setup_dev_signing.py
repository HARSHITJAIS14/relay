#!/usr/bin/env python3
"""Create a persistent preview signer in a private, build-only keychain.

Does not install a trusted root or use the user's login-Keychain password.
The private key, keychain password, and signing metadata stay under ignored .tooling/.
This is not Apple Developer ID signing or notarization.
"""
import json
import os
import re
import secrets
import shlex
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1] / ".tooling/macos-signing"
root.mkdir(parents=True, exist_ok=True)
root.chmod(0o700)
keychain = root / "relay-signing.keychain-db"
password_file = root / "password"
record = root / "signer.json"
name = "Relay Local Development"

def run(*args):
    # Never log commands/output containing the generated keychain password.
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"Signing setup failed during {args[1] if len(args) > 1 else args[0]} (exit {result.returncode}).")
    return result.stdout

if keychain.exists() and not password_file.exists():
    raise SystemExit("The preview keychain exists but its password file is missing. Restore the original signing files; do not replace the identity for routine builds.")
if not keychain.exists():
    if password_file.exists() or record.exists():
        raise SystemExit("Signing files are incomplete. Restore the original keychain before continuing.")
    password_file.write_text(secrets.token_hex(32))
    password_file.chmod(0o600)
    original_search = shlex.split(run("security", "list-keychains", "-d", "user"))
    try:
        run("security", "create-keychain", "-p", password_file.read_text(), str(keychain))
    finally:
        # Keychain creation can add a search-list entry. Keep the user's list unchanged.
        current_search = shlex.split(run("security", "list-keychains", "-d", "user"))
        if current_search != original_search:
            run("security", "list-keychains", "-d", "user", "-s", *original_search)
password = password_file.read_text()
run("security", "unlock-keychain", "-p", password, str(keychain))
identities = run("security", "find-identity", "-p", "codesigning", str(keychain))
match = re.search(r'\d+\) ([A-Fa-f0-9]{40}) "Relay Local Development"', identities)
if not match:
    if record.exists():
        raise SystemExit("The recorded signing identity is unavailable. Restore it instead of generating a different key.")
    with tempfile.TemporaryDirectory(prefix="relay-signing-") as folder:
        temp = Path(folder)
        config = temp / "certificate.cnf"
        config.write_text("""[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Relay Local Development
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
""")
        environment = {**os.environ, "RELAY_SIGNING_PASSWORD": password}
        def openssl(*args):
            result = subprocess.run(["/usr/bin/openssl", *args], env=environment, capture_output=True)
            if result.returncode:
                raise SystemExit("Could not generate the preview signing identity.")
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                "-config", str(config), "-keyout", str(temp / "key.pem"), "-out", str(temp / "cert.pem"))
        openssl("pkcs12", "-export", "-inkey", str(temp / "key.pem"), "-in", str(temp / "cert.pem"),
                "-name", name, "-out", str(temp / "identity.p12"), "-passout", "env:RELAY_SIGNING_PASSWORD")
        run("security", "import", str(temp / "identity.p12"), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign")
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain))
    identities = run("security", "find-identity", "-p", "codesigning", str(keychain))
    match = re.search(r'\d+\) ([A-Fa-f0-9]{40}) "Relay Local Development"', identities)
    if not match:
        raise SystemExit("The generated signing identity is unavailable.")
fingerprint = match.group(1)
if record.exists() and json.loads(record.read_text())["fingerprint"] != fingerprint:
    raise SystemExit("The signing identity changed unexpectedly. Restore the original signing files.")
record.write_text(json.dumps({"fingerprint": fingerprint, "keychain": str(keychain)}, indent=2) + "\n")
record.chmod(0o600)
print("Persistent Relay preview signer is ready. Login Keychain, trust roots, and search settings are unchanged.")
