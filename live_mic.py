#!/usr/bin/env python3
"""
live_mic.py
Mikrofondan canlı ses kaydedip anında Groq Whisper Large v3 (ve isteğe bağlı Gemini)
ile deşifre eden pratik interaktif araç.

Kullanım:
  python3 live_mic.py
  python3 live_mic.py --both    (Hem Groq hem Gemini'ı kıyaslamak için)
"""

import os
import sys
import time
import wave
import argparse
import threading
import numpy as np
import sounddevice as sd

from run_benchmark import load_env_file, TranscriptionRunner

def record_audio(output_wav: str = "temp_mic.wav", sample_rate: int = 16000) -> float:
    """Enter tuşuna basılana kadar mikrofondan ses kaydeder."""
    audio_frames = []
    stop_event = threading.Event()
    
    def callback(indata, frames, time_info, status):
        if status:
            print(f"[Uyarı] Ses akışı: {status}", file=sys.stderr)
        audio_frames.append(indata.copy())

    print("\n" + "=" * 60)
    input("🎤 Kaydı BAŞLATMAK için [ENTER] tuşuna basın...")
    
    start_time = time.time()
    stream = sd.InputStream(samplerate=sample_rate, channels=1, dtype="int16", callback=callback)
    
    with stream:
        print("🔴 KAYIT YAPILIYOR... (Bitirmek için [ENTER] tuşuna basın)")
        input()
        stop_event.set()
        
    duration = time.time() - start_time
    print(f"⏹️ Kayıt tamamlandı! Süre: {duration:.2f} saniye")
    
    # WAV dosyasına yaz
    audio_data = np.concatenate(audio_frames, axis=0)
    with wave.open(output_wav, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2) # 16-bit
        wf.setframerate(sample_rate)
        wf.writeframes(audio_data.tobytes())
        
    return duration

def main():
    parser = argparse.ArgumentParser(description="Canlı Mikrofon STT Deşifre")
    parser.add_argument("--both", action="store_true", help="Hem Groq hem Gemini üzerinde eşzamanlı test et")
    parser.add_argument("--model", default="whisper-large-v3", help="Groq modeli (whisper-large-v3 veya whisper-large-v3-turbo)")
    args = parser.parse_args()

    load_env_file()
    runner = TranscriptionRunner()
    
    if not runner.groq_key:
        print("[Hata] GROQ_API_KEY .env dosyasında bulunamadı!")
        sys.exit(1)

    print("=" * 60)
    print("      CANLI MİKROFON SES DEŞİFRE ARACI (GROQ)")
    print("=" * 60)
    print(f"Varsayılan Model: {args.model}")
    if args.both:
        print("Karşılaştırma Modu: Groq Whisper + Gemini 3.6 Flash")
    print("=" * 60)

    audio_file = "live_recording.wav"

    while True:
        try:
            duration = record_audio(audio_file)
            
            print(f"\n⚡ Groq ({args.model})'a gönderiliyor...")
            groq_res = runner.transcribe_groq(audio_file, model=args.model)
            
            print("\n" + "-" * 60)
            print(f"📝 GROQ METİN ({groq_res['latency']} sn):")
            print(f"   \"{groq_res['text']}\"")
            print("-" * 60)
            
            if args.both:
                print("\n⏳ Gemini (gemini-3.6-flash)'e gönderiliyor...")
                gemini_res = runner.transcribe_gemini(audio_file, model="gemini-3.6-flash")
                print("-" * 60)
                print(f"📝 GEMINI METİN ({gemini_res['latency']} sn):")
                print(f"   \"{gemini_res['text']}\"")
                print("-" * 60)
                
            print("\nTekrar konuşmak ister misiniz? (Devam etmek için [ENTER], çıkmak için [q + ENTER])")
            choice = input().strip().lower()
            if choice == "q":
                print("Çıkış yapıldı. İyi çalışmalar!")
                break
        except KeyboardInterrupt:
            print("\nProgram sonlandırıldı.")
            break

if __name__ == "__main__":
    main()
