#!/usr/bin/env python3
"""
Cift WAV basligini onarir.

Belirti: API bazen 'audio/wav' dondurur (zaten tam WAV). Uzerine bir 44 baytlik
baslik daha eklenirse dosya soyle gorunur:

    offset 0   : RIFF....WAVEfmt ...   <- uydurma baslik
    offset 44  : RIFF....WAVEfmt ...   <- GERCEK baslik
    offset 88  : PCM verisi

Sonuc: basa ~22 ms gurultu biner, sure yanlis raporlanir.

Kullanim:
    python3 tools/repair-wav.py out/clone-proof
    python3 tools/repair-wav.py dosya.wav --in-place
"""
import sys
from pathlib import Path


def find_real_header(data: bytes) -> int | None:
    """Offset 44'te ikinci bir RIFF basligi var mi?"""
    if len(data) > 56 and data[44:48] == b"RIFF" and data[52:56] == b"WAVE":
        return 44
    return None


def repair(path: Path, in_place: bool = False) -> bool:
    data = path.read_bytes()
    offset = find_real_header(data)
    if offset is None:
        print(f"  [temiz]  {path.name}")
        return False

    fixed = data[offset:]
    out = path if in_place else path.with_suffix(".fixed.wav")
    out.write_bytes(fixed)
    print(
        f"  [onarildi] {path.name} -> {out.name}  "
        f"({len(data)} -> {len(fixed)} bayt, {offset} bayt baslik atildi)"
    )
    return True


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    in_place = "--in-place" in sys.argv
    if not args:
        print(__doc__)
        return 1

    target = Path(args[0])
    files = sorted(target.glob("*.wav")) if target.is_dir() else [target]

    print(f"\n=== Cift baslik taramasi: {target} ===")
    n = sum(repair(f, in_place) for f in files)
    print(f"\n  {len(files)} dosya tarandi, {n} tanesi onarildi.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
