#!/usr/bin/env python3
"""Create a local-only signing identity in the login Keychain.

Not a distribution certificate and never added as a trusted root. Stable signing
lets Keychain distinguish normal rebuilds from a different application.
"""
import os
import secrets
import subprocess
import tempfile
from pathlib import Path

name = "Companion Local Development"
identities = subprocess.check_output(["security", "find-identity", "-p", "codesigning"], text=True)
if f'"{name}"' in identities:
    print("Local signing identity already exists.")
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix="companion-signing-") as folder:
    root = Path(folder)
    password = secrets.token_hex(32)
    config = root / "certificate.cnf"
    config.write_text("""[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Companion Local Development
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
""")
    environment = {**os.environ, "COMPANION_SIGNING_PASSWORD": password}
    def run(*args):
        subprocess.run(args, cwd=root, env=environment, check=True, capture_output=True)
    run("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "365",
        "-config", str(config), "-keyout", "key.pem", "-out", "cert.pem")
    run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem",
        "-name", name, "-out", "identity.p12", "-passout", "env:COMPANION_SIGNING_PASSWORD")
    run("security", "import", str(root / "identity.p12"), "-k",
        str(Path.home() / "Library/Keychains/login.keychain-db"),
        "-P", password, "-T", "/usr/bin/codesign")
print("Imported local development signing identity. No root trust settings changed.")
