#!/usr/bin/env python3
"""
Kaydin icinde gercekten konusma var mi? Teshis araci.

"Kayit cok sessiz" uyarisi UC farkli sorundan gelebilir ve cozumleri farklidir:

  1. DIJITAL SESSIZLIK (tam sifir)
     -> Mikrofon izni verilmemis, ya da cihaz kapali/secili degil
     -> Cozum: Sistem Ayarlari > Gizlilik > Mikrofon

  2. DUZ DUSUK GURULTU, patlama yok
     -> Ya hic konusulmadi, ya da giris sesi (input volume) ~0
     -> Cozum: osascript -e "set volume input volume 75"

  3. KONUSMA PATLAMALARI VAR ama seviye dusuk
     -> Konustunuz, mikrofon uzak veya kazanc dusuk
     -> Cozum: mikrofona yaklasin / giris sesini artirin

Kullanim:
    python3 tools/inspect-recording.py out/myvoice_raw.wav
    python3 tools/inspect-recording.py out/myvoice_raw.wav --bin 0.5
"""
import argparse
import sys
import wave
from pathlib import Path

import numpy as np

BAR = 40
DB_FLOOR = -75.0  # grafik alt siniri


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


def db(v: float) -> float:
    return 20 * np.log10(max(abs(v), 1e-10))


def rms_db(x: np.ndarray) -> float:
    if len(x) == 0:
        return -200.0
    return 20 * np.log10(max(float(np.sqrt(np.mean(x**2))), 1e-10))


def bar(value_db: float) -> str:
    norm = np.clip((value_db - DB_FLOOR) / -DB_FLOOR, 0, 1)
    filled = int(norm * BAR)
    return "#" * filled + "." * (BAR - filled)


def band_energy(x: np.ndarray, rate: int) -> dict:
    """Sesin frekans dagilimi - konusma mi, gurultu mu ayirt etmek icin."""
    if len(x) < 512:
        return {}
    win = np.hanning(len(x))
    mag = np.abs(np.fft.rfft(x * win)) ** 2
    freqs = np.fft.rfftfreq(len(x), 1 / rate)
    total = mag.sum() + 1e-20

    return {
        "rumble_%": 100 * mag[freqs < 100].sum() / total,      # ugultu / sebekle hum
        "speech_%": 100 * mag[(freqs >= 100) & (freqs < 4000)].sum() / total,  # konusma
        "hiss_%": 100 * mag[freqs >= 4000].sum() / total,      # tizlik / gurultu
        "centroid_hz": float((mag * freqs).sum() / total),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Kayit teshisi")
    ap.add_argument("input", nargs="?", default="out/myvoice_raw.wav")
    ap.add_argument("--bin", type=float, default=None, help="zaman bin suresi (sn)")
    args = ap.parse_args()

    path = Path(args.input)
    if not path.exists():
        print(f"[hata] Dosya bulunamadi: {path}")
        return 1

    x, rate = read_wav(path)
    duration = len(x) / rate

    print(f"\n=== Kayit teshisi: {path.name} ===")
    print(f"  sure       : {duration:.2f} sn")
    print(f"  ornekleme  : {rate} Hz")
    print(f"  ornek sayisi: {len(x)}")

    if len(x) == 0:
        print("\n  [HATA] Dosya bos.")
        return 1

    # --- Temel seviyeler ---
    peak = float(np.abs(x).max())
    exact_zeros = float(np.mean(x == 0.0))

    print("\n  --- Seviyeler ---")
    print(f"  tepe (peak)   : {db(peak):7.1f} dB   (konusmada -12..-3 dB beklenir)")
    print(f"  RMS           : {rms_db(x):7.1f} dB   (konusmada -26..-16 dB beklenir)")
    print(f"  tam sifir oran: %{exact_zeros*100:.2f}")

    # --- Zaman cizelgesi: konusma patlamalari var mi? ---
    bin_sec = args.bin or max(0.25, duration / 30)
    n_bins = max(1, int(duration / bin_sec))
    bin_size = len(x) // n_bins

    levels, energies = [], []
    print(f"\n  --- Zaman cizelgesi ({bin_sec:.2f} sn'lik pencereler) ---")
    for i in range(n_bins):
        seg = x[i * bin_size : (i + 1) * bin_size]
        e = rms_db(seg)
        energies.append(e)
        levels.append((i * bin_sec, e))
        if i % 2 == 0 or n_bins <= 15:  # her satiri yazdirmayalim
            print(f"  {i*bin_sec:6.1f}s |{bar(e)}| {e:7.1f} dB")

    energies = np.array(energies)

    # --- Konusma tespiti ---
    noise_floor = float(np.percentile(energies, 10))
    peak_bin = float(np.percentile(energies, 95))
    threshold = noise_floor + 8.0  # gurultu tabanindan 8 dB yuksek = aktivite
    active = np.where(energies > threshold)[0]
    active_sec = len(active) * bin_sec

    print("\n  --- Aktivite analizi ---")
    print(f"  gurultu tabani : {noise_floor:7.1f} dB")
    print(f"  en yuksek bin  : {peak_bin:7.1f} dB")
    print(f"  dinamik aralik : {peak_bin - noise_floor:7.1f} dB   (konusmada 25+ dB beklenir)")
    print(f"  aktif sure     : {active_sec:.1f} sn / {duration:.1f} sn  (%{100*active_sec/duration:.0f})")

    # --- Spektrum: sesin icerigi konusma gibi mi? ---
    info = {}
    if len(active) > 0:
        # En yuksek aktiviteli pencerenin icerigini incele
        loudest = int(active[np.argmax(energies[active])])
        seg = x[loudest * bin_size : (loudest + 1) * bin_size]
        info = band_energy(seg, rate)
        if info:
            print(f"\n  --- En yuksek aktiviteli pencere ({loudest*bin_sec:.1f}s) icerigi ---")
            print(f"  ugultu (<100Hz) : %{info['rumble_%']:.1f}   (yuksekse elektrik/ugultu sorunu)")
            print(f"  konusma bandı   : %{info['speech_%']:.1f}   (100-4000 Hz)")
            print(f"  tizlik (>4kHz)  : %{info['hiss_%']:.1f}")
            print(f"  spektral merkez : {info['centroid_hz']:.0f} Hz")

    # --- HUKUM ---
    print("\n  === HUKUM ===")

    if peak < 1e-6 or exact_zeros > 0.99:
        print("  [SORUN 1] DIJITAL SESSIZLIK - kayit tamamen sifir.")
        print("     Neden : Mikrofon izni verilmemis veya cihaz kapali.")
        print("     Cozum : Sistem Ayarlari > Gizlilik ve Guvenlik > Mikrofon")
        print("             Terminal (veya kullandiginiz uygulama) icin izni ACIN.")
        print("             Sonra terminali KAPATIP yeniden acin.")
        return 1

    if peak_bin - noise_floor < 6:
        print("  [SORUN 2] KONUSMA ALGILANMADI - kayit duz gurultu, patlama yok.")
        print(f"     Neden : Ya hic konusulmadi, ya da giris sesi ~0.")
        print("     Kontrol: osascript -e \"input volume of (get volume settings)\"")
        print("     Cozum : osascript -e \"set volume input volume 75\"")
        print("             ve tekrar kaydedin.")
        return 2

    if peak_bin < -30:
        print("  [SORUN 3] KONUSMA VAR AMA SEVIYE COK DUSUK.")
        print(f"     Konusma seviyesi {peak_bin:.1f} dB - en az -25 dB olmali.")
        print("     Neden : Mikrofon uzak veya giris kazanci dusuk.")
        print("     Cozum : 1) Giris sesini artirin:")
        print("               osascript -e \"set volume input volume 80\"")
        print("             2) Mikrofona 15 cm'e yaklasin")
        print("             3) Tekrar kaydedin")
        return 3

    print("  [OK] Kayitta konusma tespit edildi, seviye kullanilabilir.")
    print(f"     Konusma seviyesi {peak_bin:.1f} dB, dinamik aralik {peak_bin-noise_floor:.1f} dB.")
    if info and info["rumble_%"] > 50:
        print("     [NOT] Dusuk frekansli ugultu baskin - fan/klima kapatmayi deneyin.")
    print(f"\n  Sonraki adim: python3 tools/prepare-sample.py {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
