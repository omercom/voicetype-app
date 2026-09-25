#!/usr/bin/env python3
"""
Mikrofondan ses kaydeder ve klonlama icin hazirlar.

Kullanim:
    python3 tools/record-voice.py                      # 15 sn kayit, canli seviye olcer
    python3 tools/record-voice.py --seconds 25         # daha uzun
    python3 tools/record-voice.py --device 0           # belirli mikrofon
    python3 tools/record-voice.py --out out/myvoice.wav

Klonlama icin ipuclari (kaliteyi en cok bunlar etkiler):
  - SESSIZ bir odada kaydedin, klima/fan kapali
  - Mikrofona 15-25 cm mesafede konusun, dogrudan uflemeyin
  - 15-30 saniye, DOGAL bir tonla, normal konusma hizinizda
  - Cumleler arasinda kisa duraklamalar birakin (model bunlari ogreniyor)
  - Cok yavas/abartili konusmayin - taklit edilen sey bu olur
  - Cihaz hoparlorden calmasin (feedback olur), kulaklik kullanin

Cikti: 24 kHz / 16-bit / mono WAV (API'nin bekledigi format, dogrudan kullanilabilir)
"""
import argparse
import queue
import sys
import threading
import time
import wave
from pathlib import Path

import numpy as np

TARGET_RATE = 24000  # API'nin bekledigi ornekleme hizi
BAR_WIDTH = 40


def level_bar(rms: float, peak: float) -> str:
    """Canli seviye cubugu. Yesil/sari/kirmizi bolgeler - klibi onlemek icin."""
    # -60 dB .. 0 dB araligini cubuga esle
    db = 20 * np.log10(max(rms, 1e-10))
    norm = np.clip((db + 60) / 60, 0, 1)
    filled = int(norm * BAR_WIDTH)

    if peak >= 0.99:
        color = "\033[91m"  # kirmizi - KLIB (clipping)
        tag = " KLIB!"
    elif peak >= 0.7:
        color = "\033[93m"  # sari - yuksek ama tamam
        tag = " iyi"
    elif db < -30:
        color = "\033[90m"  # gri - cok sessiz
        tag = " COK SESSIZ"
    else:
        color = "\033[92m"  # yesil
        tag = ""

    bar = "█" * filled + "░" * (BAR_WIDTH - filled)
    return f"\r  {color}[{bar}]\033[0m {db:6.1f} dB{tag}   "


def check_input_volume() -> float | None:
    """
    macOS giris ses seviyesini okur. Dusukse kullaniciyi uyarir.

    Bu kontrol onemli: giris seviyesi 27 iken yapilan kayit teknik olarak
    "basarili" gorunur ama klonlama icin kullanilamaz (konusma -40 dB'de kalir).
    """
    import subprocess

    try:
        out = subprocess.run(
            ["osascript", "-e", "get volume settings"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        vol = int(out.split("input volume:")[1].split(",")[0].strip())
    except Exception:
        return None

    if vol < 50:
        print(f"\n  [UYARI] Giris ses seviyesi dusuk: {vol}/100")
        print("          Klonlama icin konusma ~-20 dB olmali, bu ayarla ~-40 dB cikar.")
        print("          Duzeltmek icin:")
        print(f"            osascript -e \"set volume input volume 80\"")
        print("          Simdi otomatik yukseltiliyor...")
        try:
            subprocess.run(
                ["osascript", "-e", "set volume input volume 80"],
                capture_output=True, timeout=5,
            )
            print("          Giris seviyesi 80'e ayarlandi.\n")
            return 80.0
        except Exception:
            print("          [hata] Ayar degistirilemedi, elle ayarlayin.\n")
    else:
        print(f"\n  Giris ses seviyesi: {vol}/100 (uygun)")

    return float(vol)


def record(seconds: float, device: int | None, out_path: Path) -> tuple[np.ndarray, int]:
    import sounddevice as sd

    # Cihazin native hizinda kaydedip sonra 24 kHz'e cevirmek yerine,
    # dogrudan 24 kHz istiyoruz - ffmpeg bagimliligini ortadan kaldirir.
    try:
        sd.check_input_settings(device=device, samplerate=TARGET_RATE, channels=1, dtype="float32")
        rate = TARGET_RATE
    except Exception:
        info = sd.query_devices(device, kind="input")
        rate = int(info["default_samplerate"])
        print(f"  [not] {TARGET_RATE} Hz desteklenmiyor, {rate} Hz kullanilacak (sonra cevrilecek)")

    q: queue.Queue = queue.Queue()
    peak_overall = 0.0
    clipped = 0

    def callback(indata, frames, time_info, status):
        nonlocal clipped
        if status:
            pass  # tasma uyarilarini sessizce yut
        mono = indata[:, 0].copy()
        q.put(mono)
        p = float(np.abs(mono).max())
        if p >= 0.99:
            clipped += 1

    print(f"\n  Kayit: {seconds:.0f} saniye, {rate} Hz, mono")
    print("  Konusmaya baslayin...\n")

    frames: list[np.ndarray] = []
    stream = sd.InputStream(
        samplerate=rate, channels=1, dtype="float32", callback=callback, device=device
    )

    with stream:
        start = time.time()
        while True:
            elapsed = time.time() - start
            if elapsed >= seconds:
                break
            try:
                chunk = q.get(timeout=0.1)
                frames.append(chunk)
                peak_overall = max(peak_overall, float(np.abs(chunk).max()))
            except queue.Empty:
                pass

            rms = float(np.sqrt(np.mean(frames[-1] ** 2))) if frames else 0.0
            remaining = seconds - elapsed
            sys.stdout.write(level_bar(rms, peak_overall) + f"[{remaining:4.1f}s kaldi]")
            sys.stdout.flush()

    print("\n")
    audio = np.concatenate(frames) if frames else np.zeros(0, dtype=np.float32)

    # Seviye degerlendirmesi - kullaniciya net geri bildirim
    if len(audio):
        rms_db = 20 * np.log10(max(float(np.sqrt(np.mean(audio**2))), 1e-10))
        peak_db = 20 * np.log10(max(float(np.abs(audio).max()), 1e-10))
        print(f"  Kayit seviyesi : RMS {rms_db:.1f} dB, tepe {peak_db:.1f} dB")
        if clipped:
            print(f"  [UYARI] {clipped} kez klip (bozulma) tespit edildi - daha uzaktan konusun")
        elif peak_db < -20:
            print("  [UYARI] Kayit cok sessiz - mikrofona yaklasin")
        else:
            print("  [OK] Seviye iyi gorunuyor")

    if rate != TARGET_RATE:
        print(f"  [not] {rate} -> {TARGET_RATE} Hz cevrilecek")

    return audio, rate


def main() -> int:
    ap = argparse.ArgumentParser(description="Klonlama icin ses kaydi")
    ap.add_argument("--seconds", type=float, default=15, help="kayit suresi (varsayilan 15)")
    ap.add_argument("--device", type=int, default=None, help="giris cihazi indeksi")
    ap.add_argument("--out", default="out/myvoice_raw.wav", help="cikti dosyasi")
    args = ap.parse_args()

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Giris seviyesi kontrolu - dusukse kayit bosa gider
    check_input_volume()

    try:
        audio, rate = record(args.seconds, args.device, out_path)
    except KeyboardInterrupt:
        print("\n  [iptal] Kayit iptal edildi.")
        return 130
    except Exception as e:
        print(f"\n  [hata] Kayit basarisiz: {e}")
        print("\n  Mikrofon izni verilmemis olabilir:")
        print("    Sistem Ayarlari > Gizlilik ve Guvenlik > Mikrofon")
        print("    Terminal / iTerm uygulamasina izin verin.")
        return 1

    if len(audio) == 0:
        print("  [hata] Hic ses kaydedilemedi.")
        return 1

    # 24 kHz'e yeniden ornekle (scipy varsa kaliteli, yoksa basit interpolasyon)
    if rate != TARGET_RATE:
        try:
            from scipy.signal import resample_poly
            from math import gcd

            g = gcd(TARGET_RATE, rate)
            audio = resample_poly(audio, TARGET_RATE // g, rate // g)
        except ImportError:
            n_out = int(len(audio) * TARGET_RATE / rate)
            audio = np.interp(np.linspace(0, len(audio) - 1, n_out), np.arange(len(audio)), audio)

    # 16-bit PCM olarak yaz
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(out_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TARGET_RATE)
        w.writeframes(pcm.tobytes())

    dur = len(pcm) / TARGET_RATE
    print(f"  Kaydedildi: {out_path}  ({dur:.1f} sn, {out_path.stat().st_size / 1024:.0f} KB)")
    print(f"\n  Sonraki adim: python3 tools/prepare-sample.py {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
