#!/usr/bin/env python3
"""
Kaydedilmis bir ses dosyasini klonlama icin hazirlar ve kalitesini olcer.

API'nin istedigi format: 24 kHz, 16-bit, mono, WAV.

Yaptigi isler:
  1. Formati 24 kHz / 16-bit / mono'ya cevirir (ffmpeg ile)
  2. Sessizlikleri kirpar (basi/sonu temizler)
  3. Kalite metriklerini olcer: sure, SNR, klip orani, sessizlik orani
  4. Klonlama icin yeterli mi diye net bir hukum verir

Kullanim:
    python3 tools/prepare-sample.py out/myvoice_raw.wav
    python3 tools/prepare-sample.py giris.m4a --out out/klon-ornegim.wav
    python3 tools/prepare-sample.py out/myvoice_raw.wav --keep-silence
"""
import argparse
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

TARGET_RATE = 24000
MIN_SECONDS = 5.0     # bunun altinda klonlama ogrenemez
GOOD_SECONDS = 10.0   # ideal minimum
MAX_SECONDS = 60.0    # cok uzun ornek gerekmez


def convert(src: Path, dst: Path) -> None:
    """ffmpeg ile tam format donusumu."""
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg bulunamadi (brew install ffmpeg)")

    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(src),
        "-ac", "1",              # mono
        "-ar", str(TARGET_RATE), # 24 kHz
        "-c:a", "pcm_s16le",     # 16-bit little-endian
        str(dst),
    ]
    subprocess.run(cmd, check=True)


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        width = w.getsampwidth()
        raw = w.readframes(w.getnframes())
    dtype = {1: np.int8, 2: np.int16, 4: np.int32}[width]
    x = np.frombuffer(raw, dtype=dtype).astype(np.float64)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x / np.iinfo(dtype).max, rate


def write_wav(path: Path, x: np.ndarray, rate: int) -> None:
    pcm = (np.clip(x, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


def trim_silence(x: np.ndarray, rate: int, thresh_db: float = -40.0, pad_ms: int = 150):
    """Bastaki/sondaki sessizligi kirpar, konusma aralarini korur."""
    size, hop = 512, 256
    if len(x) < size:
        return x, 0.0

    energies = []
    for i in range(0, len(x) - size + 1, hop):
        seg = x[i : i + size]
        energies.append(20 * np.log10(max(float(np.sqrt(np.mean(seg**2))), 1e-10)))

    energies = np.array(energies)
    active = np.where(energies > thresh_db)[0]
    if len(active) == 0:
        return x, 0.0

    pad = int(pad_ms / 1000 * rate)
    start = max(0, active[0] * hop - pad)
    end = min(len(x), active[-1] * hop + size + pad)
    removed = (len(x) - (end - start)) / rate
    return x[start:end], removed


def analyze(x: np.ndarray, rate: int) -> dict:
    """
    Kalite metrikleri.

    Duzeltme notu: gurultu tabani olarak tum karelerin 10. yuzdeligini almak
    YANILTICI. Kayitta uzun sessizlik varsa bu deger cok dusuk cikar ve SNR
    oldugundan yuksek gorunur. Dogrusu:
      - konusma seviyesi : aktif karelerin medyani
      - gurultu tabani   : aktif OLMAYAN karelerin medyani
      - SNR              : ikisinin farki
    Ayrica "aktif kare" esigi konusma seviyesine gore belirlenir.
    """
    size, hop = 512, 256
    frames = [x[i : i + size] for i in range(0, len(x) - size + 1, hop)]
    if not frames:
        return {}

    rms = np.array([float(np.sqrt(np.mean(f**2))) for f in frames])
    db = 20 * np.log10(np.maximum(rms, 1e-10))

    # Konusma seviyesini ust yuzdelikten tahmin et
    speech_db = float(np.percentile(db, 90))
    # Konusmayi esikle: konusma seviyesinin 15 dB altindan yuksek kareler aktif
    active_mask = db > (speech_db - 15.0)
    active_db = db[active_mask]
    quiet_db = db[~active_mask]

    # Gurultu tabani: aktif olmayan karelerin medyani (yoksa en sessiz %20)
    noise_db = float(np.median(quiet_db)) if len(quiet_db) > 3 else float(np.percentile(db, 5))

    return {
        "duration": len(x) / rate,
        "peak_db": 20 * np.log10(max(float(np.abs(x).max()), 1e-10)),
        "speech_db": float(np.median(active_db)) if len(active_db) else speech_db,
        "noise_floor_db": noise_db,
        "snr_db": (float(np.median(active_db)) if len(active_db) else speech_db) - noise_db,
        "silence_ratio": float(np.mean(db < (speech_db - 15.0))),
        "clip_ratio": float(np.mean(np.abs(x) > 0.995)),
    }


def verdict(m: dict) -> tuple[bool, list[str]]:
    """Klonlama icin yeterli mi? Sorunlari listeler."""
    problems: list[str] = []
    dur = m["duration"]

    if dur < MIN_SECONDS:
        problems.append(f"Ornek cok kisa ({dur:.1f} sn) - en az {MIN_SECONDS:.0f} sn gerekir")
    elif dur < GOOD_SECONDS:
        problems.append(f"Ornek kisa ({dur:.1f} sn) - {GOOD_SECONDS:.0f}+ sn daha iyi sonuc verir")
    elif dur > MAX_SECONDS:
        problems.append(f"Ornek cok uzun ({dur:.1f} sn) - {MAX_SECONDS:.0f} sn yeterli")

    if m["clip_ratio"] > 0.001:
        problems.append(f"Klip/bozulma var (%{m['clip_ratio']*100:.2f}) - daha uzaktan kaydedin")
    if m["snr_db"] < 15:
        problems.append(f"Gurultu fazla (SNR {m['snr_db']:.1f} dB) - sessiz oda gerekli, hedef 20+ dB")
    if m["silence_ratio"] > 0.7:
        problems.append(f"Sessizlik orani yuksek (%{m['silence_ratio']*100:.0f}) - daha cok konusun")
    if m["speech_db"] < -35:
        problems.append("Kayit cok sessiz - mikrofona yaklasin")

    return len(problems) == 0, problems


def main() -> int:
    ap = argparse.ArgumentParser(description="Klonlama ornegini hazirla ve denetle")
    ap.add_argument("input", help="giris ses dosyasi (wav/m4a/mp3/...)")
    ap.add_argument("--out", default=None, help="cikti dosyasi")
    ap.add_argument("--keep-silence", action="store_true", help="sessizlik kirpmayi atla")
    ap.add_argument("--no-normalize", action="store_true", help="kazanc normalizasyonunu atla")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.exists():
        print(f"[hata] Dosya bulunamadi: {src}")
        return 1

    out = Path(args.out) if args.out else src.with_name(src.stem + "_clean.wav")
    out.parent.mkdir(parents=True, exist_ok=True)

    print(f"\n=== Ornek hazirlama: {src.name} ===")

    tmp = out.with_suffix(".tmp.wav")
    try:
        convert(src, tmp)
        print("  format : 24 kHz / 16-bit / mono'ya cevrildi")
    except Exception as e:
        print(f"  [hata] Donusum basarisiz: {e}")
        return 1

    x, rate = read_wav(tmp)
    before = analyze(x, rate)

    if not args.keep_silence:
        x, removed = trim_silence(x, rate)
        if removed > 0.05:
            print(f"  temizlik: {removed:.1f} sn sessizlik kirpildi")

    # --- Normalizasyon ---
    # Giris kazanci dusukse kayit -40 dB civarinda kalir. Bu durumda tepe
    # seviyeyi hedefe cekmek kaydi kurtarir; ama gurultuyu de yukselttigi
    # icin yalnizca SNR iyiyse uygulanir.
    target_peak_db = -3.0
    peak_db = 20 * np.log10(max(float(np.abs(x).max()), 1e-10))

    # Gurultu tabani ile konusma arasindaki fark
    frame = 512
    rms_list = [
        float(np.sqrt(np.mean(x[i : i + frame] ** 2)))
        for i in range(0, len(x) - frame + 1, frame)
    ]
    if rms_list:
        dbs = 20 * np.log10(np.maximum(np.array(rms_list), 1e-10))
        snr_est = float(np.percentile(dbs, 90) - np.percentile(dbs, 10))
    else:
        snr_est = 0.0

    if not args.no_normalize and peak_db < -6.0 and snr_est > 15:
        gain_db = target_peak_db - peak_db
        gain = 10 ** (gain_db / 20)
        x = np.clip(x * gain, -1.0, 1.0)
        print(f"  kazanc : {gain_db:+.1f} dB uygulandi (tepe {peak_db:.1f} -> {target_peak_db:.1f} dB)")
    elif peak_db < -6.0:
        print(f"  kazanc : uygulanmadi - SNR dusuk ({snr_est:.1f} dB), gurultu de yukselirdi")
        print("           Daha iyi bir kayit yapmaniz onerilir.")

    write_wav(out, x, rate)
    tmp.unlink(missing_ok=True)

    m = analyze(x, rate)
    print("\n  --- Kalite olcumleri ---")
    prev = f"  (kirpma oncesi {before['duration']:.2f} sn)" if before else ""
    print(f"  sure          : {m['duration']:.2f} sn{prev}")
    print(f"  tepe seviye   : {m['peak_db']:.1f} dB")
    print(f"  konusma (med) : {m['speech_db']:.1f} dB")
    print(f"  gurultu tabani: {m['noise_floor_db']:.1f} dB")
    print(f"  SNR           : {m['snr_db']:.1f} dB   (hedef: 20+)")
    print(f"  sessizlik     : %{m['silence_ratio']*100:.0f}")
    print(f"  klip orani    : %{m['clip_ratio']*100:.3f}")

    ok, problems = verdict(m)
    print()
    if ok:
        print("  [HAZIR] Bu ornek klonlama icin uygun gorunuyor.")
    else:
        print("  [DIKKAT] Sorunlar:")
        for p in problems:
            print(f"    - {p}")

    print(f"\n  Cikti: {out}")
    print("\n  Klonlamak icin:")
    print(f"    node src/voice-clone.ts --model gemini-3.8-flash-tts --sample {out} \\")
    print('      --text "Merhaba, bu benim kendi sesimle uretilmis bir denemedir."')
    return 0


if __name__ == "__main__":
    sys.exit(main())
