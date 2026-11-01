"""Chrome Native Messaging host. No network access, shell commands, or text logs."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
import uuid

MAX_BYTES = 262144


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.read(count - len(result))
        if not chunk:
            raise ValueError("Eksik mesaj")
        result.extend(chunk)
    return bytes(result)


def read_message(stream):
    length = struct.unpack("=I", read_exact(stream, 4))[0]
    if not 0 < length <= MAX_BYTES:
        raise ValueError("Geçersiz mesaj uzunluğu")
    return json.loads(read_exact(stream, length))


def validate_request(request):
    if not isinstance(request, dict) or request.get("action") not in ("speak", "stop", "pause", "resume", "status"):
        raise ValueError("Geçersiz komut")
    if not isinstance(request.get("id"), str):
        raise ValueError("Geçersiz kimlik")
    identifier = str(uuid.UUID(request.get("id", "")))
    result = {"action": request["action"], "id": identifier}
    if request["action"] == "speak":
        text = request.get("text")
        if not isinstance(text, str) or not text.strip() or len(text.strip()) > 30000:
            raise ValueError("Geçersiz metin")
        result["text"] = text.strip()
    return result


def forward(request):
    path = Path.home() / ".voice_typing/tts/browser.sock"
    deadline = time.monotonic() + 4
    launched = False
    while True:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(3)
        try:
            connection.connect(str(path))
            break
        except (FileNotFoundError, ConnectionRefusedError):
            connection.close()
            if not launched:
                subprocess.run(["/usr/bin/open", "-b", "com.antigravity.VoiceTyping"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2, check=True)
                launched = True
            if time.monotonic() >= deadline:
                raise ConnectionError("VoiceType açılamadı")
            time.sleep(0.1)
        except Exception:
            connection.close()
            raise
    with connection:
        connection.sendall(json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n")
        with connection.makefile("rb") as stream:
            line = stream.readline(MAX_BYTES + 1)
        if not line.endswith(b"\n") or len(line) > MAX_BYTES:
            raise ValueError("Geçersiz uygulama yanıtı")
        response = json.loads(line)
        if not isinstance(response, dict) or not isinstance(response.get("ok"), bool):
            raise ValueError("Geçersiz uygulama yanıtı")
        return response


def main():
    try:
        allowed = json.loads(Path(__file__).with_name("origin.json").read_text())
        if len(sys.argv) < 2 or sys.argv[1].rstrip("/") != allowed.rstrip("/"):
            raise PermissionError("Geçersiz eklenti")
        response = forward(validate_request(read_message(sys.stdin.buffer)))
    except Exception:
        response = {"ok": False, "error": "VoiceType bağlantısı kurulamadı. Uygulamayı ve setup-chrome.sh kurulumunu kontrol edin."}
    encoded = json.dumps(response, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("=I", len(encoded)) + encoded)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
