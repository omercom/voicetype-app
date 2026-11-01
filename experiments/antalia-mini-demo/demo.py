#!/usr/bin/env python3
"""Local Turkish TTS demo. Playback and disk I/O stay outside timed sections."""
import argparse
from datetime import datetime, timezone
from importlib.metadata import version
import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

DEFAULT_TEXTS = [
    "Merhaba! Bu ses yapay zekâ ile üretilmiştir. VoiceType artık Türkçe metinleri sesli okuyabilir.",
    "Toplantı yarın saat 14:30'da başlayacak. Lütfen raporu kontrol edip ekibe gönderin.",
    "Sesle yazdığınız metni dinleyerek kontrol edebilirsiniz. Bu model konuşmayı yazıya çevirmez, "
    "yazıyı sese çevirir. İlk kurulumdan sonra internet bağlantısı olmadan çalışabilir.",
    "Toplam tutar 1.250,75 TL. Randevunuz 14 Ekim 2026 günü saat 15:30'da, Dr. Ayşe Yılmaz ile.",
    "Öğleden sonra ılık bir çay içtik. Işık, çığ, yağmur ve gökyüzü hakkında konuştuk.",
    "Toplantı bağlantısını WhatsApp üzerinden gönderdim. Python ve GitHub ile çalışıyoruz.",
    "Evet. Tamam! Hayır, teşekkür ederim. Şimdi devam edelim.",
    "İstanbul'un iki yakasını birbirine bağlayan köprüler, her gün yüz binlerce kişinin işe, "
    "okula ve evine ulaşmasını sağlıyor. Ancak yoğun saatlerde trafik yolculuk süresini uzatıyor. "
    "Bu yüzden yola çıkmadan önce güzergâhınızı kontrol edin. Alternatif yolları da değerlendirin.",
]

MODEL_REVISION = "1e8166a7436f3e11f7f03b339258ec30f366db60"


def positive_int(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("Değer en az 1 olmalı.")
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Antalia Mini: Türkçe ses demosu ve hız ölçümü")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--text", help="Okunacak Türkçe metin")
    source.add_argument("--file", type=Path, help="UTF-8 metin dosyası")
    source.add_argument("--clipboard", action="store_true", help="macOS panosundaki metni oku")
    parser.add_argument("--device", choices=("cpu", "mps", "cuda"), default="cpu",
                        help="CPU varsayılan; MPS deneysel; CUDA NVIDIA gerektirir")
    parser.add_argument("--threads", type=positive_int, default=2, help="CPU iş parçacığı sayısı")
    parser.add_argument("--runs", type=positive_int, default=3, help="Isınma sonrası tekrar sayısı")
    parser.add_argument("--play", action="store_true", help="Ölçümden sonra WAV dosyalarını çal")
    parser.add_argument("--offline", action="store_true", help="Yalnızca önbellekteki ağırlıkları kullan")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "output")
    return parser.parse_args(argv)


def load_texts(args):
    if args.clipboard:
        if sys.platform != "darwin":
            raise ValueError("Pano desteği yalnızca macOS içindir.")
        text = subprocess.run(["/usr/bin/pbpaste"], check=True, capture_output=True,
                              text=True, encoding="utf-8", timeout=5).stdout
    elif args.file:
        text = args.file.read_text(encoding="utf-8")
    elif args.text is not None:
        text = args.text
    else:
        return list(DEFAULT_TEXTS)
    text = text.strip()
    if not text:
        raise ValueError("Okunacak metin boş.")
    if len(text) > 10000:
        raise ValueError("Demo en fazla 10000 karakter kabul eder.")
    return [text]


def metrics(elapsed, duration, first=None):
    if elapsed <= 0 or duration <= 0:
        raise ValueError("Üretim ve ses süresi sıfırdan büyük olmalı.")
    result = {"generation_ms": elapsed * 1000, "audio_seconds": duration,
              "rtf": elapsed / duration, "realtime_factor": duration / elapsed}
    if first is not None:
        result["first_chunk_ms"] = first * 1000
    return result


def measure_say(tts, text):
    start = time.perf_counter()
    speech = tts.say(text, seed=0)
    elapsed = time.perf_counter() - start
    return metrics(elapsed, speech.duration), speech


def measure_stream(tts, text, rate=48000):
    start = time.perf_counter()
    first = None
    samples = 0
    count = 0
    for chunk in tts.stream(text, seed=0):
        if not len(chunk):
            continue
        if first is None:
            first = time.perf_counter() - start
        samples += len(chunk)
        count += 1
    elapsed = time.perf_counter() - start
    if first is None:
        raise ValueError("Model ses üretmedi.")
    return {**metrics(elapsed, samples / rate, first), "chunks": count}


def main(argv=None):
    args = parse_args(argv)
    texts = load_texts(args)
    if args.play and sys.platform != "darwin":
        raise ValueError("Ses çalma desteği yalnızca macOS içindir.")
    if args.offline:
        import os
        os.environ["HF_HUB_OFFLINE"] = "1"
    import_start = time.perf_counter()
    import torch
    from antalia_mini import Antalia
    import_seconds = time.perf_counter() - import_start
    torch.set_num_threads(args.threads)
    if args.device == "mps" and not torch.backends.mps.is_available():
        raise ValueError("MPS bu cihazda kullanılamıyor.")
    if args.device == "cuda" and not torch.cuda.is_available():
        raise ValueError("CUDA bu cihazda kullanılamıyor.")
    print(f"Antalia Mini yükleniyor: {args.device}, {args.threads} CPU iş parçacığı", flush=True)
    start = time.perf_counter()
    tts = Antalia(device=args.device, threads=args.threads, revision=MODEL_REVISION, warmup=False)
    load_seconds = time.perf_counter() - start
    cold, _ = measure_say(tts, texts[0])
    measure_stream(tts, texts[0])  # warm both paths before collecting repeat timings
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    wav_paths = []
    for index, text in enumerate(texts, 1):
        warm_say, _ = measure_say(tts, text)
        warm_stream = measure_stream(tts, text)
        say_runs, stream_runs = [], []
        for _ in range(args.runs):
            say_result, speech = measure_say(tts, text)
            say_runs.append(say_result)
            stream_runs.append(measure_stream(tts, text))
        wav_path = args.output / f"demo-{index:02d}.wav"
        speech.save(wav_path)
        wav_paths.append(wav_path)
        say_ms = statistics.median(r["generation_ms"] for r in say_runs)
        first_ms = statistics.median(r["first_chunk_ms"] for r in stream_runs)
        factor = statistics.median(r["realtime_factor"] for r in say_runs)
        rows.append({"text": text, "normalized_text": tts.normalize(text), "wav": wav_path.name, "say_runs": say_runs,
                     "warmup_say": warm_say, "warmup_stream": warm_stream,
                     "stream_runs": stream_runs, "median_generation_ms": say_ms,
                     "median_first_chunk_ms": first_ms, "median_realtime_factor": factor})
        print(f"{index}: {speech.duration:.2f} sn ses | üretim {say_ms:.1f} ms | "
              f"ilk parça {first_ms:.1f} ms | {factor:.1f}× gerçek zaman", flush=True)
    cpu_name = platform.processor()
    if sys.platform == "darwin":
        cpu_name = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
                                  capture_output=True, text=True, check=True).stdout.strip()
    report = {"created_at": datetime.now(timezone.utc).isoformat(),
              "model": "cloud0day3/antalia-mini", "antalia_version": version("antalia-mini"),
              "model_revision": MODEL_REVISION,
              "torch_version": torch.__version__, "python": platform.python_version(),
              "platform": platform.platform(), "cpu": cpu_name, "device": str(tts.device),
              "threads": args.threads, "seed": 0, "sample_rate": 48000, "runs": args.runs,
              "import_seconds": import_seconds, "model_load_seconds": load_seconds,
              "cold_say": cold, "results": rows,
              "notes": ["WAV yazma ve ses çalma ölçüm dışında.",
                        "İlk parça gecikmesi hoparlörden duyulma gecikmesi değildir.",
                        "Yükleme süresi ilk çalışmada indirmeyi içerebilir.",
                        "Metinler ve WAV dosyaları yerelde saklanır; özel metni paylaşmayın."]}
    report_path = args.output / "benchmark.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Rapor: {report_path}\nBu ses yapay zekâ ile üretilmiştir.", flush=True)
    if args.play:
        for path in wav_paths:
            subprocess.run(["/usr/bin/afplay", str(path)], check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Demo hatası: {error}", file=sys.stderr)
        raise SystemExit(1)
