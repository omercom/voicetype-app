"""Private JSON-lines worker. stdout is protocol-only; text is never logged."""
import contextlib
import json
import os
from pathlib import Path
import sys
import uuid

MAX_CHARACTERS = 5000
MODEL_REPO = "cloud0day3/antalia-mini"
MODEL_REVISION = "1e8166a7436f3e11f7f03b339258ec30f366db60"


def request_from_line(line):
    request = json.loads(line)
    if not isinstance(request, dict) or not isinstance(request.get("id"), str) or not isinstance(request.get("text"), str):
        raise ValueError("Geçersiz istek")
    identifier = str(uuid.UUID(request["id"]))
    text = request["text"].strip()
    if not text or len(text) > MAX_CHARACTERS:
        raise ValueError("Geçersiz metin uzunluğu")
    return identifier, text


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)


def load_model(offline=True):
    if offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from antalia_mini import Antalia
        from huggingface_hub import snapshot_download
        # Resolve explicitly: Antalia's plain HTTPS fallback does not enforce offline mode.
        model_path = snapshot_download(
            MODEL_REPO, revision=MODEL_REVISION, local_files_only=offline,
            allow_patterns=["config.json", "acoustic.safetensors", "vocoder.safetensors"],
        )
        torch.set_num_threads(2)
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        try:
            model = Antalia(model=model_path, device=device, threads=2)
            model.say("Merhaba. Bu ses yapay zekâ ile üretilmiştir.", seed=0)
        except Exception:
            if device == "cpu":
                raise
            device = "cpu"
            model = Antalia(model=model_path, device=device, threads=2)
            model.say("Merhaba. Bu ses yapay zekâ ile üretilmiştir.", seed=0)
    return model, device


def main():
    prepare = "--prepare" in sys.argv
    try:
        model, device = load_model(offline=not prepare)
    except Exception as error:
        emit("error", message="Antalia Mini yüklenemedi. setup-tts.sh ile motoru kurun.")
        print(f"Antalia startup: {type(error).__name__}", file=sys.stderr)
        return 1
    emit("ready", device=device)
    if prepare:
        return 0
    output = Path(os.environ["VOICETYPE_TTS_OUTPUT"])
    for line in sys.stdin:
        identifier = None
        try:
            identifier, text = request_from_line(line)
            path = output / f"{identifier}.wav"
            with contextlib.redirect_stdout(sys.stderr):
                speech = model.say(text, seed=0, path=str(path))
            os.chmod(path, 0o600)
            emit("audio", id=identifier, path=str(path), duration=speech.duration)
        except Exception as error:
            emit("error", id=identifier, message="Ses üretilemedi. Motoru yeniden başlatın.")
            print(f"Antalia request: {type(error).__name__}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
