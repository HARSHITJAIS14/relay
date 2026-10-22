#!/usr/bin/env python3
"""Bundle the native executable as Relay.app."""
import argparse
import os
import json
import re
import shlex
import plistlib
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--allow-adhoc", action="store_true", help="Explicitly allow unstable local-only signing")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
signing_keychain = None
identities = subprocess.check_output(["security", "find-identity", "-p", "codesigning"], text=True)
choices = dict((name, fingerprint) for fingerprint, name in re.findall(r'\d+\) ([A-Fa-f0-9]{40}) "([^"\n]+)"', identities))
signer = os.environ.get("RELAY_SIGNING_IDENTITY")
if not signer:
    preferred = next((name for name in choices if name.startswith("Developer ID Application:")), None)
    if preferred:
        signer = choices[preferred]
    else:
        record = root / ".tooling/macos-signing/signer.json"
        if record.exists():
            config = json.loads(record.read_text())
            signing_keychain = config["keychain"]
            signer = config["fingerprint"]
if not signer or signer == "-":
    if not args.allow_adhoc:
        raise SystemExit("Stable signing is required. Configure RELAY_SIGNING_IDENTITY with a Developer ID identity, or run python3 tools/setup_dev_signing.py for preview builds. Use --allow-adhoc only for disposable local builds.")
    signer = "-"
subprocess.run(["swift", "build", "-c", "release", "--package-path", str(root / "apps/macos")], check=True)
bundle = root / "apps/macos/.build/Relay.app"
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "apps/macos/.build/release/Companion", contents / "MacOS/Relay")
for item in (root / "apps/macos/Resources").glob("*"):
    shutil.copy2(item, contents / "Resources" / item.name)
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({
        "CFBundleIdentifier": "dev.relay.macos",
        "CFBundleName": "Relay",
        "CFBundleExecutable": "Relay",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "9",
        "CFBundleShortVersionString": "1.6.3",
        "LSMinimumSystemVersion": "13.0",
        "NSLocalNetworkUsageDescription": "Connect securely to your paired phone and transfer your selected files.",
        "NSBonjourServices": ["_relay._tcp", "_companion._tcp"],
    }, stream)
sign_args = ["codesign", "--force", "--sign", signer]
original_search = None
try:
    if signing_keychain:
        # macOS needs the private build keychain in its lookup list while signing.
        # Restore the exact original list even if signing fails.
        original_search = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
        if signing_keychain not in original_search:
            subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original_search, signing_keychain], check=True, capture_output=True)
        password_file = root / ".tooling/macos-signing/password"
        result = subprocess.run(["security", "unlock-keychain", "-p", password_file.read_text(), signing_keychain], capture_output=True)
        if result.returncode:
            raise SystemExit("Could not unlock the private build-signing keychain.")
        sign_args += ["--keychain", signing_keychain]
    subprocess.run([*sign_args, str(bundle)], check=True)
finally:
    if original_search is not None:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original_search], check=True, capture_output=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
if signer == "-":
    print("Ad-hoc signing: Keychain may request access again after rebuilds.")
else:
    print("Signed with a persistent identity. Preview signing does not provide Apple notarization.")
print(bundle)
