#!/usr/bin/env python3
"""Create Relay's permanent local release keystore once; never replace an existing key."""
import os
from pathlib import Path
import secrets
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
folder = root / '.tooling/android-signing'
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
folder.chmod(0o700)
keystore = folder / 'relay-release.p12'
properties = folder / 'release.properties'
if keystore.exists() or properties.exists():
    if not (keystore.exists() and properties.exists()):
        raise SystemExit('Incomplete signing setup. Restore the original files; do not replace the key.')
    print('Existing release signing files retained.')
    raise SystemExit(0)
keytool = shutil.which('keytool')
if os.environ.get('JAVA_HOME'):
    keytool = str(Path(os.environ['JAVA_HOME']) / 'bin/keytool')
if not keytool:
    raise SystemExit('Set JAVA_HOME to JDK 17 first.')
password = secrets.token_hex(32)
env = dict(os.environ, RELAY_STORE_PASSWORD=password)
os.umask(0o077)
subprocess.run([keytool, '-genkeypair', '-keystore', str(keystore),
    '-storetype', 'PKCS12', '-storepass:env', 'RELAY_STORE_PASSWORD',
    '-keypass:env', 'RELAY_STORE_PASSWORD', '-alias', 'relay-release',
    '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
    '-dname', 'CN=Harshit Jaiswal, OU=Relay', '-noprompt'], env=env, check=True)
properties.write_text('storeFile=relay-release.p12\nstorePassword=' + password +
    '\nkeyAlias=relay-release\nkeyPassword=' + password + '\n')
keystore.chmod(0o600)
properties.chmod(0o600)
print('Permanent release key created in .tooling/android-signing/. Back up this private folder securely.')
