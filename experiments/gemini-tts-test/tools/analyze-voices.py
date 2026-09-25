#!/usr/bin/env python3
"""
Klonlama dogrulamasi icin akustik analiz.

Uc dosyayi karsilastirir:
  A_prebuilt_Fola   - referans ses 1
  B_prebuilt_Zephyr - referans ses 2
  C_clone_from_Zephyr - Zephyr orneginden klonlanan

Olcumler: temel frekans (F0/pitch), spektral merkez, MFCC.
Beklenti: C, B'ye A'dan daha yakin.
"""
import sys
import wave
from pathlib import Path

import numpy as np


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        rate = w.getframerate()
        channels = w.getnchannels()
        width = w.getsampwidth()
        raw = w.readframes(w.getnframes())
    dtype = {1: np.int8, 2: np.int16, 4: np.int32}[width]
    data = np.frombuffer(raw, dtype=dtype).astype(np.float64)
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data / np.iinfo(dtype).max, rate


def frames(x: np.ndarray, size: int, hop: int):
    for i in range(0, len(x) - size + 1, hop):
        yield x[i : i + size]


def rms_db(x: np.ndarray) -> float:
    return 20 * np.log10(np.sqrt(np.mean(x**2)) + 1e-12)


def frame_energy_db(x: np.ndarray, size: int = 1024, hop: int = 512) -> np.ndarray:
    return np.array([rms_db(f) for f in frames(x, size, hop)])


def voiced(x: np.ndarray, size: int = 1024, hop: int = 512) -> np.ndarray:
    """Sessizlikleri at: konusmanin aktif oldugu bolgeler."""
    idx = np.array(range(0, len(x) - size + 1, hop))
    e = frame_energy_db(x, size, hop)
    if len(e) == 0:
        return np.zeros(size)
    thr = np.percentile(e, 70) - 12
    keep = idx[e > thr]
    if len(keep) == 0:
        return x
    return np.concatenate([x[i : i + size] for i in keep])


def estimate_f0(x: np.ndarray, rate: int, fmin: float = 70, fmax: float = 350) -> float:
    """
    Otokorelasyon tabanli temel frekans tahmini (medyan).

    Oktav hatasi duzeltmesi: otokorelasyonda periyodun YARISI da yuksek tepe
    verir, bu da F0'i iki katina cikarir. Bu yuzden global tepeyi bulduktan
    sonra, periyodun tam kati olan daha buyuk lag'ler kontrol edilir; otokorelasyon
    hala yeterince yuksekse daha buyuk lag (daha dusuk F0) tercih edilir.
    Onceki surumde bu kontrol yoktu ve olcum ust sinira dayaniyordu.
    """
    size, hop = 2048, 1024
    lag_min, lag_max = int(rate / fmax), int(rate / fmin)
    est = []

    for f in frames(x, size, hop):
        if rms_db(f) < -45:
            continue
        f = f - f.mean()
        ac = np.correlate(f, f, mode="full")[size - 1 :]
        if ac[0] <= 0:
            continue
        ac = ac / ac[0]

        seg = ac[lag_min:lag_max]
        if len(seg) == 0:
            continue

        # Ilk anlamli tepeyi bul (global maksimum degil - gurultuye dayanikli)
        lag = int(np.argmax(seg)) + lag_min
        if ac[lag] <= 0.3:
            continue

        # Oktav duzeltmesi: periyodun 2x, 3x katlari da kontrol et
        for mult in (2, 3):
            cand = lag * mult
            if lag_max > cand >= lag_min and ac[cand] > 0.85 * ac[lag]:
                lag = cand  # daha dusuk F0, gercek periyot

        est.append(rate / lag)

    return float(np.median(est)) if est else float("nan")


def spectral_centroid(x: np.ndarray, rate: int) -> float:
    size, hop = 1024, 512
    vals = []
    win = np.hanning(size)
    for f in frames(x, size, hop):
        if rms_db(f) < -45:
            continue
        mag = np.abs(np.fft.rfft(f * win))
        freqs = np.fft.rfftfreq(size, 1 / rate)
        if mag.sum() > 0:
            vals.append(float((mag * freqs).sum() / mag.sum()))
    return float(np.median(vals)) if vals else float("nan")


def mfcc(x: np.ndarray, rate: int, n_mfcc: int = 13, n_mels: int = 26) -> np.ndarray:
    """Basit MFCC - ortalama vektor."""
    size, hop = 1024, 512
    win = np.hanning(size)

    def hz2mel(f):
        return 2595 * np.log10(1 + f / 700)

    def mel2hz(m):
        return 700 * (10 ** (m / 2595) - 1)

    mel_pts = mel2hz(np.linspace(hz2mel(50), hz2mel(rate / 2), n_mels + 2))
    bins = np.floor((size + 1) * mel_pts / rate).astype(int)
    filters = np.zeros((n_mels, size // 2 + 1))
    for i in range(1, n_mels + 1):
        lo, mid, hi = bins[i - 1], bins[i], bins[i + 1]
        if mid > lo:
            filters[i - 1, lo:mid] = (np.arange(lo, mid) - lo) / (mid - lo)
        if hi > mid:
            filters[i - 1, mid:hi] = (hi - np.arange(mid, hi)) / (hi - mid)

    vecs = []
    for f in frames(x, size, hop):
        if rms_db(f) < -45:
            continue
        mag = np.abs(np.fft.rfft(f * win)) ** 2
        mel = np.log(filters @ mag + 1e-10)
        dct = np.cos(np.pi / n_mels * (np.arange(n_mfcc)[:, None] * (np.arange(n_mels)[None, :] + 0.5)))
        vecs.append(dct @ mel)

    return np.mean(vecs, axis=0) if vecs else np.zeros(n_mfcc)


def cos_dist(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return float("nan")
    return float(1 - np.dot(a, b) / (na * nb))


def main():
    d = Path(sys.argv[1] if len(sys.argv) > 1 else "out/clone-proof")
    files = {p.stem: p for p in sorted(d.glob("*.wav"))}
    if len(files) < 3:
        print(f"[hata] {d} icinde en az 3 wav bekleniyordu, {len(files)} bulundu.")
        print("       Once: node src/clone-proof.ts")
        return 1

    feats = {}
    print(f"\n=== Akustik analiz: {d} ===")
    print(f"{'dosya':<24}{'F0 (Hz)':>10}{'spektral merkez':>18}{'RMS (dB)':>11}")
    print("-" * 63)

    for name, path in files.items():
        x, rate = read_wav(path)
        v = voiced(x)
        f0 = estimate_f0(v, rate)
        sc = spectral_centroid(v, rate)
        feats[name] = {"mfcc": mfcc(v, rate), "f0": f0}
        print(f"{name:<24}{f0:>10.1f}{sc:>18.0f}{rms_db(x):>11.1f}")

    names = list(feats)
    print("\n=== MFCC kosinus mesafesi (kucuk = daha benzer) ===")
    print(f"{'karsilastirma':<44}{'mesafe':>10}")
    print("-" * 54)
    for i, a in enumerate(names):
        for b in names[i + 1 :]:
            print(f"{a + '  vs  ' + b:<44}{cos_dist(feats[a]['mfcc'], feats[b]['mfcc']):>10.4f}")

    clone_key = next((n for n in names if "clone" in n.lower()), None)
    if clone_key:
        c = feats[clone_key]
        others = [(n, feats[n]) for n in names if n != clone_key]
        print(f"\n=== SONUC: {clone_key} nereye yakin? ===")
        ranked = []
        for ref_name, ref_feat in others:
            df0 = abs(c["f0"] - ref_feat["f0"])
            dmfcc = cos_dist(c["mfcc"], ref_feat["mfcc"])
            ranked.append((df0, dmfcc, ref_name))
        # En kucuk MFCC mesafesi = en benzer
        for df0, dmfcc, ref_name in sorted(ranked, key=lambda r: r[1]):
            print(f"  {ref_name:<28} dF0={df0:>6.1f} Hz   dMFCC={dmfcc:.4f}")
        best = min(ranked, key=lambda r: r[1])
        print(f"\n  -> En yakin referans: {best[2]}")
        print("     Klonlama calisiyorsa bu, KAYNAK ses olmali.")
    else:
        print("\n  [not] 'clone' iceren dosya bulunamadi, sadece genel karsilastirma yapildi.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
