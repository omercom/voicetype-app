"""Install only this extension's per-user Native Messaging host."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import sys


def extension_id(key):
    digest = hashlib.sha256(base64.b64decode(key, validate=True)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(nibble, 16)) for nibble in digest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, help="Optional isolated Chrome user-data directory for testing")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "chrome/manifest.json").read_text())
    identifier = extension_id(manifest["key"])
    origin = f"chrome-extension://{identifier}/"
    target = Path.home() / ".voice_typing/tts/browser-host"
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    target.chmod(0o700)
    shutil.copyfile(root / "native_host.py", target / "native_host.py")
    (target / "origin.json").write_text(json.dumps(origin) + "\n")
    for file in [target / "native_host.py", target / "origin.json"]:
        file.chmod(0o600)
    executable = target / "run"
    executable.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(target / 'native_host.py'))} \"$@\"\n")
    executable.chmod(0o700)
    data = {"name": "com.voicetype.ema", "description": "VoiceType local Turkish read aloud",
            "path": str(executable), "type": "stdio", "allowed_origins": [origin]}
    profiles = [args.profile] if args.profile else [
        Path.home() / "Library/Application Support/Google/Chrome",
        Path.home() / "Library/Application Support/Google/ChromeForTesting",
    ]
    for profile in profiles:
        folder = profile / "NativeMessagingHosts"
        folder.mkdir(parents=True, exist_ok=True)
        file = folder / "com.voicetype.ema.json"
        file.write_text(json.dumps(data, indent=2) + "\n")
        file.chmod(0o600)
    print(f"✅ Chrome yerel bağlantısı hazır. Eklenti kimliği: {identifier}")
    print(f"Chrome → chrome://extensions → Geliştirici modu → Paketlenmemiş öğe yükle: {root / 'chrome'}")


if __name__ == "__main__":
    main()
