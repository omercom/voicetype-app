#!/usr/bin/env python3
"""
Mikrofon kayit yolunu test eder: hangi ornekleme hizinda daha iyi seviye aliyoruz?

Suphe: MacBook Air mikrofonu 48 kHz native. 24 kHz isteyince macOS farkli bir
sinyal yolu kullaniyor olabilir ve seviye dusebilir.

Yontem: Ayni anda hem 48 kHz hem 24 kHz kaydedip seviyeleri karsilastirir.
Kullanici iki kez konusur: bir "bir" der, sonra "iki" der.

Kullanim:
    python3 tools/test-mic-paths.py --seconds 6
"""
import argparse
import queue
import sys
import time
import wave
from pathlib import Path

import numpy as np


def db(v: float) -> float:
    return 20 * np.log10(max(abs(v), 1e-10))


def rms_db(x: np.ndarray) -> float:
    if len(x) == 0:
        return -200.0
    return 20 * np.log10(max(float(np.sqrt(np.mean(x**2))), 1e-10))


def record_at(rate: int, seconds: float, device: int | None) -> np.ndarray:
    import sounddevice as sd

    q: queue.Queue = queue.Queue()

    def cb(indata, frames, time_info, status):
        q.put(indata[:, 0].copy())

    frames = []
    with sd.InputStream(samplerate=rate, channels=1, dtype="float32",
                        callback=cb, device=device):
        start = time.time()
        while time.time() - start < seconds:
            try:
                frames.append(q.get(timeout=0.1))
            except queue.Empty:
                pass

    return np.concatenate(frames) if frames else np.zeros(0, dtype=np.float32)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=6, help="her kayit icin sure")
    ap.add_argument("--device", type=int, default=None)
    args = ap.parse_args()

    results = []

    for rate in (48000, 24000):
        print(f"\n{'='*60}")
        print(f"  {rate} Hz'de kayit - {args.seconds:.0f} saniye")
        print(f"{'='*60}")
        print("  >>> Konusun! Normal ses tonuyla bir seyler soyleyin. <<<\n")

        # Geri sayim
        for i in (3, 2, 1):
            sys.stdout.write(f"\r  Basliyor... {i}")
            sys.stdout.flush()
            time.sleep(1)
        print("\r  KAYIT BAŞLADI              ")

        x = record_at(rate, args.seconds, args.device)

        peak = float(np.abs(x).max()) if len(x) else 0.0
        print(f"\n  tepe : {db(peak):7.1f} dB")
        print(f"  RMS  : {rms_db(x):7.1f} dB")

        # Aktivite: konusma var mi?
        size = 512
        rmsf = np.array([
            float(np.sqrt(np.mean(x[i:i+size]**2)))
            for i in range(0, max(1, len(x)-size+1), size)
        ])
        dbs = 20 * np.log10(np.maximum(rmsf, 1e-10)) if len(rmsf) else np.array([-200.0])
        dynamic = float(np.percentile(dbs, 95) - np.percentile(dbs, 10))
        print(f"  dinamik aralik: {dynamic:5.1f} dB  ({'konusma var' if dynamic > 12 else 'KONUSMA YOK'})")

        results.append((rate, db(peak), rms_db(x), dynamic, x))

    # Karsilastirma
    print(f"\n{'='*60}")
    print("  KARSILASTIRMA")
    print(f"{'='*60}")
    print(f"  {'hz':>8}  {'tepe':>9}  {'rms':>9}  {'dinamik':>9}")
    print("  " + "-" * 40)
    for rate, peak, rms, dyn, _ in results:
        print(f"  {rate:>8}  {peak:>9.1f}  {rms:>9.1f}  {dyn:>9.1f}")

    base = next(r for r in results if r[0] == 48000)
    other = next(r for r in results if r[0] == 24000)
    diff = other[1] - base[1]

    print()
    if abs(diff) < 3:
        print(f"  [SONUC] Fark onemsiz ({diff:+.1f} dB). 24 kHz dogrudan kullanilabilir.")
    elif diff < 0:
        print(f"  [SONUC] 48 kHz {abs(diff):.1f} dB DAHA IYI.")
        print("          24 kHz'de seviye dusuyor; 48 kHz'de kaydedip sonra cevirmek daha iyi.")
    else:
        print(f"  [SONUC] 24 kHz {diff:.1f} dB daha iyi (beklenmedik).")

    # En iyi kaydi sakla
    best = max(results, key=lambda r: r[1])
    out = Path(f"out/micpath_{best[0]}hz.wav")
    out.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(best[4], -1, 1) * 32767).astype(np.int16)
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(best[0])
        w.writeframes(pcm.tobytes())
    print(f"\n  En iyi kayit saklandi: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
