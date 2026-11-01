"""Local Seda STT worker. stdout contains only the JSON result, never logs."""
import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import sys
import wave
import uuid

MODEL_REPO = "atasoglu/seda-v0.1"
MODEL_REVISION = "b5cf32ae4936968b284df3f1c4c79714af71e1fe"
MODEL_FILES = ["README.md", "tokens.txt", "encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx",
               "lm/rnnlm.int8.onnx", "lm/2gram.fst"]


def load_recognizer(prepare=False):
    if not prepare:
        os.environ["HF_HUB_OFFLINE"] = "1"
    from huggingface_hub import snapshot_download
    import sherpa_onnx

    home = Path(os.environ.get("VOICETYPE_SEDA_HOME", Path.home() / ".voice_typing/stt/seda"))
    directory = Path(snapshot_download(
        MODEL_REPO, revision=MODEL_REVISION, allow_patterns=MODEL_FILES,
        cache_dir=str(home / "models"), local_files_only=not prepare,
    ))
    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=str(directory / "tokens.txt"), encoder=str(directory / "encoder.int8.onnx"),
        decoder=str(directory / "decoder.onnx"), joiner=str(directory / "joiner.int8.onnx"),
        num_threads=2, sample_rate=16000, feature_dim=80, provider="cpu",
        decoding_method="modified_beam_search", max_active_paths=4,
        lm=str(directory / "lm/rnnlm.int8.onnx"), lm_scale=0.6,
        lodr_fst=str(directory / "lm/2gram.fst"), lodr_scale=-0.5,
    )
    return recognizer, home


def transcribe(recognizer, path):
    import numpy as np

    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels() != 1 or audio.getsampwidth() != 2
                or audio.getframerate() != 16000 or audio.getcomptype() != "NONE"):
            raise ValueError("Expected 16 kHz mono PCM16 WAV")
        frames = audio.getnframes()
        if not 0 < frames <= 16000 * 600:
            raise ValueError("Expected at most 10 minutes of audio")
        raw = audio.readframes(frames)
        if len(raw) != frames * 2:
            raise ValueError("Truncated WAV")
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    stream = recognizer.create_stream()
    # Bound decoding memory by consuming the audio in 100 ms pieces.
    for start in range(0, len(samples), 1600):
        stream.accept_waveform(16000, samples[start:start + 1600])
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
    stream.accept_waveform(16000, np.zeros(16000, dtype=np.float32))
    stream.input_finished()
    while recognizer.is_ready(stream):
        recognizer.decode_stream(stream)
    return recognizer.get_result(stream)


class StreamingDecoder:
    """One continuous utterance; pauses never reset or lose earlier words."""
    def __init__(self, recognizer):
        self.recognizer = recognizer
        self.stream = None
        self.identifier = None
        self.samples = 0
        self.previous_text = ""

    def handle(self, request):
        import numpy as np

        operation = request.get("op")
        identifier = str(uuid.UUID(request["id"]))
        if operation == "start":
            if self.stream is not None:
                raise ValueError("Stream already active")
            self.identifier = identifier
            self.stream = self.recognizer.create_stream()
            self.samples = 0
            self.previous_text = ""
            return {"event": "started", "id": identifier}
        if self.stream is None or identifier != self.identifier:
            raise ValueError("Stale or missing stream")
        if operation == "audio":
            raw = base64.b64decode(request["pcm"], validate=True)
            if not raw or len(raw) % 2 or len(raw) > 32000:
                raise ValueError("Invalid PCM16 chunk")
            self.samples += len(raw) // 2
            if self.samples > 16000 * 600:
                raise ValueError("Audio exceeds 10 minutes")
            samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            self.stream.accept_waveform(16000, samples)
        elif operation == "finish":
            # Preserve the same final-chunk flush used by WAV transcription.
            self.stream.accept_waveform(16000, np.zeros(16000, dtype=np.float32))
            self.stream.input_finished()
        else:
            raise ValueError("Unknown streaming operation")
        while self.recognizer.is_ready(self.stream):
            self.recognizer.decode_stream(self.stream)
        text = self.recognizer.get_result(self.stream)
        if operation == "finish":
            self.stream = None
            self.identifier = None
            return {"event": "final", "id": identifier, "text": text}
        if text and text != self.previous_text:
            self.previous_text = text
            return {"event": "interim", "id": identifier, "text": text}
        return None


def serve(recognizer):
    decoder = StreamingDecoder(recognizer)
    print(json.dumps({"ready": True}), flush=True)
    while True:
        line = sys.stdin.readline(100001)
        if not line:
            return
        if len(line) > 100000:
            raise ValueError("Request too large")
        request = None
        try:
            request = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr):
                if "op" in request:
                    response = decoder.handle(request)
                else:
                    if decoder.stream is not None:
                        raise ValueError("Batch request during streaming")
                    response = {"text": transcribe(recognizer, Path(request["audio"]))}
            if response is not None:
                print(json.dumps(response, ensure_ascii=False), flush=True)
        except Exception as error:
            identifier = request.get("id") if isinstance(request, dict) else None
            decoder.stream = None
            decoder.identifier = None
            print(json.dumps({"event": "error", "id": identifier,
                              "error": "Seda-v0.1 ses kaydını çözümleyemedi."}), flush=True)
            print(f"Seda request: {type(error).__name__}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--audio", type=Path)
    args = parser.parse_args()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            recognizer, home = load_recognizer(prepare=args.prepare)
            if args.prepare:
                # Decode silence to check the runtime before marking installation ready.
                import numpy as np
                stream = recognizer.create_stream()
                stream.accept_waveform(16000, np.zeros(32000, dtype=np.float32))
                stream.input_finished()
                while recognizer.is_ready(stream):
                    recognizer.decode_stream(stream)
                marker = home / "ready.json"
                marker.write_text(json.dumps({"model": MODEL_REPO, "revision": MODEL_REVISION}))
                marker.chmod(0o600)
                text = ""
            elif args.serve:
                text = None
            else:
                if args.audio is None:
                    raise ValueError("Missing WAV path")
                text = transcribe(recognizer, args.audio)
        if args.serve:
            serve(recognizer)
        else:
            print(json.dumps({"text": text}, ensure_ascii=False), flush=True)
        return 0
    except Exception as error:
        print(json.dumps({"error": "Seda-v0.1 işlemi başarısız. setup-stt.sh ile kurulumu kontrol edin."}), flush=True)
        print(f"Seda worker: {type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
