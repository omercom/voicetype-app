# Türkçe Konuşma Deşifre (STT) Benchmark: Groq Whisper vs. Google Gemini

Bu proje, Türkçe ses kayıtlarını metne dökmede (transcription / Speech-to-Text) **Groq Whisper** (`whisper-large-v3`, `whisper-large-v3-turbo`) ile **Google Gemini** (`gemini-2.5-flash` / multimodal ses) modellerinin doğruluk, hız ve Türkçe dil kurallarına uyumunu kıyaslamak için tasarlanmış bağımsız bir benchmark altyapısıdır.

---

## 1. Test Kategorileri ve Zorluk Kriterleri

Benchmark seti, Türkçede ses modellerinin en çok zorlandığı 5 kritik senaryoyu içerir:

1. **Günlük Konuşma & Soru Ekleri (`01_gunluk_konusma.mp3`):**
   - Soru eki ayrımı (`-mı / -mi`), kesme işaretli özel isimler (`Kadıköy'deki`), günlük iş jargonu.
2. **Hızlı Konuşma & Fonetik Zorluk (`02_hizli_tekerleme.mp3`):**
   - %30 artırılmış konuşma hızı, Türkçe sert sessizler (`ş`, `ç`, `s`), birbirini tekrar eden heceler ve tekerlemeler.
3. **Teknik & İngilizce Melez Terimler (`03_teknik_hibrit_terimler.mp3`):**
   - Türkçe cümle içinde geçen yabancı yazılışlı teknik terimler (`FastAPI`, `Docker`, `PostgreSQL`, `endpoint'ler`, `cache`).
4. **Sayılar, Tarihler, Saat & Para Birimleri (`04_sayilar_ve_tarihler.mp3`):**
   - Rakamların yazıyla mı sayıyla mı yazıldığı, oranlar (`yüzde 18`), saat (`14.30`), takvim tarihleri ve para tutarları.
5. **Aglütinatif Morfoloji & Bağlaçlar (`05_morfoloji_ve_ekler.mp3`):**
   - Uzun çekim/yapım ekleri (`netleştiremediklerimizden`), `de/da` bağlaç ayrımı ve soru kalıpları.

---

## 2. Değerlendirilen Metrikler

- **WER (Word Error Rate - Kelime Hata Oranı):** Standartlaştırılmış Türkçe metin üzerinden kelime düzeyinde hata oranı. (Düşük olması daha iyidir)
- **CER (Character Error Rate - Karakter Hata Oranı):** Türkçe gibi eklemeli (aglütinatif) dillerde morfolojik doğruluğu en iyi yansıtan karakter düzeyinde hata oranı.
- **Türkçe Özel Karakter Başarımı:** `ç, ğ, ı, ö, ş, ü` harflerinin ASCII'ye bozulmadan korunma yüzdesi.
- **Gecikme (Latency):** İstek başına geçen süre (saniye).
- **Maliyet / Kota Verimliliği:** Groq'un günlük 8 saat ücretsiz Whisper kotası ile Gemini'ın ücretsiz RPM limitleri.

---

## 3. Kurulum ve Çalıştırma

### A) API Anahtarlarını Ayarlama
Proje dizininde bir `.env` dosyası oluşturun:
```bash
cp .env.example .env
```
`.env` dosyasını açıp anahtarlarınızı girin:
```ini
GROQ_API_KEY=gsk_...
GEMINI_API_KEY=AIza...
```

### B) Sentetik Test Seslerini Yeniden Üretmek (İsteğe Bağlı)
```bash
python3 generate_samples.py
```

### C) Tam Benchmark Testini Başlatma
```bash
python3 run_benchmark.py
```

İsterseniz anahtarları doğrudan komut satırından da verebilirsiniz:
```bash
python3 run_benchmark.py --groq-key gsk_xxx --gemini-key AIza_xxx
```

### D) Kendi Özel Ses Dosyanızı Test Etme
Elinizdeki herhangi bir ses dosyasını (`.mp3`, `.wav`) test etmek için:
```bash
python3 run_benchmark.py --audio sesim.mp3 --ground-truth "Burada konuşulan metin"
```
*(Ground truth verilmezse modellerin deşifreleri yan yana yazdırılır ve süreleri kıyaslanır).*
