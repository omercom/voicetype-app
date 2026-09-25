#!/usr/bin/env python3
"""
Konusmaci karsilastirma - otokorelasyon yerine CEPSTRUM tabanli F0.

Neden cepstrum: otokorelasyon yontemi bant sinirli/temiz olmayan konusmada
sik sik oktav hatasi yapar (F0'i 2x veya 3x gosterir). Cepstrum, harmonik
yiginin periyodikligini log-spektrumda arar ve cok daha kararli sonuc verir.

Ek olarak harmonik-genis bant orani (HNR) olculur: konusmanin "tonlu" olup
olmadigini gosterir. Konusma yuksek HNR verir, gurultu vermez.

Kullanim:
    python3 tools/compare-voices.py out/myvoice-test
    python3 tools/compare-voices.py dosya1.wav dosya2.wav
"""
import sys
import wave
from pathlib import Path

import numpy as np


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        rate, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    dtype = {1: np.int8, 2: np.int16, 4: np.int32}[width]
    x = np.frombuffer(raw, dtype=dtype).astype(np.float64)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x / np.iinfo(dtype).max, rate


def pre_emphasis(x: np.ndarray, coef: float = 0.97) -> np.ndarray:
    """Tiz bilesenleri guclendirir - F0 tespitini belirgin sekilde iyilestirir."""
    return np.append(x[0], x[1:] - coef * x[:-1])


def f0_cepstrum(frame: np.ndarray, rate: int, fmin: float = 70, fmax: float = 350) -> float | None:
    """
    Tek kare icin cepstrum tabanli F0.

    Yontem: log-spektrumun ters FFT'si (cepstrum). Harmonik bir sesin
    cepstrumunda, temel periyoda karsilik gelen quefrency'de belirgin tepe olusur.
    """
    n = len(frame)
    spec = np.fft.rfft(frame * np.hanning(n))
    log_spec = np.log(np.abs(spec) + 1e-10)
    cep = np.fft.irfft(log_spec)

    q_min, q_max = int(rate / fmax), int(rate / fmin)
    if q_max >= len(cep):
        return None

    seg = cep[q_min:q_max]
    if len(seg) < 3:
        return None

    peak = int(np.argmax(seg))
    # Tepenin gurultuye karsi anlamli olup olmadigini kontrol et
    if seg[peak] < 0.05 * np.std(cep) + np.mean(seg):
        return None

    return rate / (peak + q_min)


def hnr(frame: np.ndarray, rate: int) -> float:
    """Harmonik-gurultu orani (dB). Yuksek = tonlu (konusma)."""
    n = len(frame)
    spec = np.abs(np.fft.rfft(frame * np.hanning(n)))
    if spec.sum() <= 0:
        return -100.0
    freqs = np.fft.rfftfreq(n, 1 / rate)
    harmonic = spec[(freqs > 70) & (freqs < 3500)].sum()
    total = spec.sum()
    if total <= 0 or harmonic >= total:
        return -100.0
    return 10 * np.log10(harmonic / (total - harmonic))


def estimate_f0(x: np.ndarray, rate: int) -> float:
    """
    Cepstrum tabanli, kare bazli medyan F0.

    Not: enerji tabanli kare secimi BURADA yapilir. Disaridan buyuk bir
    "konusma" dizisi secip buraya vermek yanlistir - cepstrum 2048 ornekli
    kareler uzerinde calismalidir.
    """
    size, hop = 2048, 512
    x = pre_emphasis(x)
    vals = []
    for i in range(0, len(x) - size + 1, hop):
        f = x[i : i + size]
        if 20 * np.log10(max(np.sqrt(np.mean(f**2)), 1e-10)) < -40:
            continue
        v = f0_cepstrum(f, rate)
        if v is not None:
            vals.append(v)
    return float(np.median(vals)) if vals else float("nan")


def mfcc(x: np.ndarray, rate: int, n_mfcc: int = 20, n_mels: int = 30) -> np.ndarray:
    size, hop = 1024, 512
    win = np.hanning(size)

    def hz2mel(f):
        return 2595 * np.log10(1 + f / 700)

    def mel2hz(m):
        return 700 * (10 ** (m / 2595) - 1)

    pts = mel2hz(np.linspace(hz2mel(60), hz2mel(min(rate / 2, 8000)), n_mels + 2))
    bins = np.floor((size + 1) * pts / rate).astype(int)
    filt = np.zeros((n_mels, size // 2 + 1))
    for i in range(1, n_mels + 1):
        lo, mid, hi = bins[i - 1], bins[i], bins[i + 1]
        if mid > lo:
            filt[i - 1, lo:mid] = np.arange(lo, mid) - lo
        if hi > mid:
            filt[i - 1, mid:hi] = hi - np.arange(mid, hi)
        s = filt[i - 1].sum()
        if s > 0:
            filt[i - 1] /= s

    dct = np.cos(np.pi / n_mels * (np.arange(n_mfcc)[:, None] * (np.arange(n_mels)[None, :] + 0.5)))
    vecs = []
    for i in range(0, len(x) - size + 1, hop):
        f = x[i : i + size]
        if 20 * np.log10(max(np.sqrt(np.mean(f**2)), 1e-10)) < -40:
            continue
        mag = np.abs(np.fft.rfft(f * win)) ** 2
        mel = np.log(filt @ mag + 1e-10)
        vecs.append(dct @ mel)

    if not vecs:
        return np.zeros(n_mfcc)
    # Ortalama + standart sapma birlikte kullanilir (konusmaci kimligi daha iyi temsil edilir)
    return np.concatenate([np.mean(vecs, axis=0), np.std(vecs, axis=0)])


def cos_dist(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return float("nan")
    return float(1 - np.dot(a, b) / (na * nb))


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1

    target = Path(args[0])
    files = sorted(target.glob("*.wav")) if target.is_dir() else [Path(a) for a in args]

    feats = {}
    print(f"\n=== Konusmaci analizi ({len(files)} dosya) ===")
    print(f"{'dosya':<28}{'sure':>8}{'F0':>9}{'HNR':>9}")
    print("-" * 56)

    for p in files:
        if not p.exists():
            print(f"  [atlandi] {p}")
            continue
        x, rate = read_wav(p)

        # Sessizlikleri bant gecirerek azalt (kare secimi fonksiyon icinde yapilir)
        f0 = estimate_f0(x, rate)
        h = float(np.median([
            hnr(x[i : i + 2048], rate) for i in range(0, max(1, len(x) - 2048), 2048)
        ])) if len(x) > 2048 else -100.0

        feats[p.stem] = {"mfcc": mfcc(x, rate), "f0": f0, "hnr": h}
        print(f"{p.stem:<28}{len(x)/rate:>7.1f}s{f0:>8.1f}Hz{h:>8.1f}dB")

    names = list(feats)
    if len(names) < 2:
        print("\n  [not] Karsilastirma icin en az 2 dosya gerekli.")
        return 0

    print("\n=== MFCC mesafesi (kucuk = benzer konusmaci) ===")
    print(f"{'karsilastirma':<46}{'mesafe':>10}")
    print("-" * 56)
    pairs = []
    for i, a in enumerate(names):
        for b in names[i + 1 :]:
            d = cos_dist(feats[a]["mfcc"], feats[b]["mfcc"])
            pairs.append((d, a, b))
            print(f"{a + ' vs ' + b:<46}{d:>10.4f}")

    # Yorum
    clone = next((n for n in names if "clone" in n.lower() or "klon" in n.lower()), None)
    if clone:
        print(f"\n=== SONUC: {clone} nereye yakin? ===")
        others = [(n, feats[n]) for n in names if n != clone]
        ranked = sorted(
            ((abs(feats[clone]["f0"] - f["f0"]), cos_dist(feats[clone]["mfcc"], f["mfcc"]), n)
             for n, f in others),
            key=lambda r: r[1],
        )
        for df0, dmfcc, n in ranked:
            print(f"  {n:<28} dF0={df0:>6.1f} Hz  dMFCC={dmfcc:.4f}")
        best = ranked[0]
        print(f"\n  -> En yakin: {best[2]}")
        print("     Klonlama calisiyorsa bu, kaynak ses olmali.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
