#!/usr/bin/env python3
"""Bundle the native executable as Relay.app."""
import plistlib
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
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
        "CFBundleVersion": "4",
        "CFBundleShortVersionString": "1.4.0",
        "LSMinimumSystemVersion": "13.0",
        "NSLocalNetworkUsageDescription": "Connect securely to your paired phone and transfer your selected files.",
        "NSBonjourServices": ["_relay._tcp", "_companion._tcp"],
    }, stream)
identities = subprocess.check_output(["security", "find-identity", "-p", "codesigning"], text=True)
signer = "Companion Local Development" if '"Companion Local Development"' in identities else "-"
subprocess.run(["codesign", "--force", "--sign", signer, str(bundle)], check=True)
if signer == "-":
    print("Ad-hoc signing: Keychain may request access again after rebuilds.")
print(bundle)
