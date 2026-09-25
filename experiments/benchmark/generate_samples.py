#!/usr/bin/env python3
"""
generate_samples.py
Türkçe konuşma tanıma (STT) benchmark testleri için kontrollü ses dosyaları üretir.
Edge TTS kullanarak farklı hız, ton ve zorluk seviyelerinde test seti oluşturur.
"""

import os
import json
import asyncio
import edge_tts

SAMPLES_DIR = os.path.join(os.path.dirname(__file__), "samples")
METADATA_FILE = os.path.join(SAMPLES_DIR, "samples_metadata.json")

TEST_CASES = [
    {
        "id": "01_gunluk_konusma",
        "category": "Günlük Konuşma & Soru Ekleri",
        "voice": "tr-TR-AhmetNeural",
        "rate": "+0%",
        "text": "Merhaba, yarın sabah erkenden Kadıköy'deki kafede buluşup haftalık sprint planlamasını yapalım mı? Gelirken dizüstü bilgisayarını getirmeyi unutma.",
        "description": "Günlük iş konuşması, soru eki ayrımı (-mı) ve kesme işaretli özel isimler."
    },
    {
        "id": "02_hizli_tekerleme",
        "category": "Hızlı Konuşma & Fonetik Zorluk",
        "voice": "tr-TR-EmelNeural",
        "rate": "+30%",
        "text": "Şu köşe yaz köşesi, şu köşe kış köşesi, ortadaki su şişesi. Çatalca'da topal çoban çatal yapıp çatal satar, nesi için Çatalca'da topal çoban çatal yapıp çatal satar?",
        "description": "+30% yüksek konuşma hızında Türkçe sert sessizler (ş, ç, s) ve tekerleme tekrar döngüleri."
    },
    {
        "id": "03_teknik_hibrit_terimler",
        "category": "Teknik & İngilizce Melez Terimler",
        "voice": "tr-TR-AhmetNeural",
        "rate": "+0%",
        "text": "Backend mimarimizde PostgreSQL veritabanını Docker konteynerleri üzerinde ayağa kaldırıp FastAPI ile asenkron endpoint'ler oluşturduk. Cache yönetimi için de Redis kullanıyoruz.",
        "description": "Türkçe cümle yapısı içine gömülü İngilizce yazılışlı teknik terimler ve kodlama kavramları."
    },
    {
        "id": "04_sayilar_ve_tarihler",
        "category": "Sayılar, Tarihler, Saat & Para",
        "voice": "tr-TR-EmelNeural",
        "rate": "+0%",
        "text": "Şirketin 2026 yılı ilk çeyrek net kârı yüzde 18 artışla 350 bin 500 liraya ulaştı. Bir sonraki genel kurul toplantısı 15 Ekim saat 14.30'da Ankara'da yapılacak.",
        "description": "Rakamlar, oranlar, takvim tarihleri, saatler ve para miktarları."
    },
    {
        "id": "05_morfoloji_ve_ekler",
        "category": "Aglütinatif Morfoloji & Bağlaçlar",
        "voice": "tr-TR-AhmetNeural",
        "rate": "+0%",
        "text": "Onların da bu konuda çekinceleri varmış fakat bizim netleştiremediklerimizden dolayı henüz kesin bir karar veremediler. Sen de bizimle gelecek misin?",
        "description": "Uzun Türkçe çekim ve yapım ekleri (netleştiremediklerimizden), 'de/da' bağlaç ayrımı ve soru kalıpları."
    }
]

async def generate_all():
    os.makedirs(SAMPLES_DIR, exist_ok=True)
    custom_dir = os.path.join(SAMPLES_DIR, "custom")
    os.makedirs(custom_dir, exist_ok=True)
    
    # Custom klasörü için .gitkeep
    gitkeep = os.path.join(custom_dir, ".gitkeep")
    if not os.path.exists(gitkeep):
        with open(gitkeep, "w") as f:
            pass

    metadata = []
    print("=== Türkçe Test Sesleri Üretiliyor ===")
    
    for item in TEST_CASES:
        filename = f"{item['id']}.mp3"
        filepath = os.path.join(SAMPLES_DIR, filename)
        
        print(f"[{item['id']}] Üretiliyor... ({item['voice']}, Hız: {item['rate']})")
        communicate = edge_tts.Communicate(
            text=item["text"],
            voice=item["voice"],
            rate=item["rate"]
        )
        await communicate.save(filepath)
        
        metadata.append({
            "id": item["id"],
            "filename": filename,
            "filepath": filepath,
            "category": item["category"],
            "voice": item["voice"],
            "rate": item["rate"],
            "ground_truth": item["text"],
            "description": item["description"]
        })
    
    with open(METADATA_FILE, "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)
        
    print(f"\nBaşarıyla {len(metadata)} adet ses örneği oluşturuldu!")
    print(f"Metadata dosyası: {METADATA_FILE}")

if __name__ == "__main__":
    asyncio.run(generate_all())
