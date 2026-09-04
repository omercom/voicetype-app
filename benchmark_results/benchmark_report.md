# Türkçe Ses Deşifre (Speech-to-Text) Benchmark Raporu

Bu rapor, **Groq Whisper** ve **Google Gemini** modellerinin Türkçe konuşma tanıma başarımını karşılaştırır.

## Özet Tablo

| Model | Ortalama WER (%) | Ortalama CER (%) | TR Karakter İsabeti (%) | Ortalama Süre (sn) |
|---|---|---|---|---|
| Groq Whisper Large v3 | %10.69 | %2.49 | %98.46 | 0.42 sn |
| Groq Whisper Large v3 Turbo | %9.73 | %2.49 | %98.46 | 0.22 sn |
| Gemini (gemini-3.6-flash) | %5.28 | %2.06 | %95.6 | 9.21 sn |

## Detaylı Karşılaştırmalar

### Günlük Konuşma & Soru Ekleri (`01_gunluk_konusma`)

- **Referans (Ground Truth):** "Merhaba, yarın sabah erkenden Kadıköy'deki kafede buluşup haftalık sprint planlamasını yapalım mı? Gelirken dizüstü bilgisayarını getirmeyi unutma."

- **Groq Whisper Large v3** (0.473 sn):
  - Deşifre: "Merhaba, yarın sabah erkenden Kadıköy'deki kafede buluşup haftalık sprint planlamasını yapalım mı? Gelirken dizüstü bilgisayarını getirmeyi unutma."
  - WER: %0.0 | CER: %0.0 | TR Harf: %100.0

- **Groq Whisper Large v3 Turbo** (0.271 sn):
  - Deşifre: "Merhaba, yarın sabah erkenden Kadıköy'deki kafede buluşup haftalık sprint planlamasını yapalım mı? Gelirken dizüstü bilgisayarını getirmeyi unutma."
  - WER: %0.0 | CER: %0.0 | TR Harf: %100.0

- **Gemini (gemini-3.6-flash)** (12.486 sn):
  - Deşifre: "Merhaba, yarın sabah erkenden Kadıköy'deki kafede buluşup haftalık sprint planlamasını yapalım mı? Gelirken dizüstü bilgisayarını getirmeyi unutma."
  - WER: %0.0 | CER: %0.0 | TR Harf: %100.0

### Hızlı Konuşma & Fonetik Zorluk (`02_hizli_tekerleme`)

- **Referans (Ground Truth):** "Şu köşe yaz köşesi, şu köşe kış köşesi, ortadaki su şişesi. Çatalca'da topal çoban çatal yapıp çatal satar, nesi için Çatalca'da topal çoban çatal yapıp çatal satar?"

- **Groq Whisper Large v3** (0.493 sn):
  - Deşifre: "Şu köşe yaz köşesi, şu köşe kış köşesi, ortadaki su şişesi. Çatalca'da topal çoban çatal yapıp çatal satar. Nesi için Çatalca'da topal çoban çatal yapıp çatal satar?"
  - WER: %0.0 | CER: %0.0 | TR Harf: %100.0

- **Groq Whisper Large v3 Turbo** (0.174 sn):
  - Deşifre: "Şu köşe yaz köşesi, şu köşe kış köşesi, ortadaki su şişesi. Çatalca da topal çoban çatal yapıp çatal satar, nesi için çatalca da topal çoban çatal yapıp çatal satar?"
  - WER: %0.0 | CER: %0.0 | TR Harf: %100.0

- **Gemini (gemini-3.6-flash)** (22.001 sn):
  - Deşifre: "Şu köşe yaz köşesi, şu köşe kış köşesi, ortadaki su şişesi. Çatalca'da topal çoban çatal yapıp çatal satar, nesi için Çatalca'da topal çoban çatal yapıp çatal satar?"
  - WER: %0.0 | CER: %0.0 | TR Harf: %100.0

### Teknik & İngilizce Melez Terimler (`03_teknik_hibrit_terimler`)

- **Referans (Ground Truth):** "Backend mimarimizde PostgreSQL veritabanını Docker konteynerleri üzerinde ayağa kaldırıp FastAPI ile asenkron endpoint'ler oluşturduk. Cache yönetimi için de Redis kullanıyoruz."

- **Groq Whisper Large v3** (0.389 sn):
  - Deşifre: "Backend mimarimizde Postgres veri tabanını doker konteynerleri üzerinde ayağa kaldırıp FastAPI ile asenkron endpointler oluşturduk. Cache yönetimi içinde Redis kullanıyoruz."
  - WER: %38.1 | CER: %3.43 | TR Harf: %100.0

- **Groq Whisper Large v3 Turbo** (0.171 sn):
  - Deşifre: "Backend mimarimizde Postgres veritabanını Docker konteynerleri üzerinde, ayağa kaldırıp Fastup'ı ile asenkron endpointler oluşturduk. Cache yönetimi içinde Redis kullanıyoruz."
  - WER: %33.33 | CER: %3.43 | TR Harf: %100.0

- **Gemini (gemini-3.6-flash)** (3.951 sn):
  - Deşifre: "Backend mimarimizde PostgreSQL veri tabanını Docker konteynerleri üzerinde ayağa kaldırıp FastAPI ile asenkron endpoint'ler oluşturduk. Cache yönetimi için de Redis kullanıyoruz."
  - WER: %9.52 | CER: %0.57 | TR Harf: %100.0

### Sayılar, Tarihler, Saat & Para (`04_sayilar_ve_tarihler`)

- **Referans (Ground Truth):** "Şirketin 2026 yılı ilk çeyrek net kârı yüzde 18 artışla 350 bin 500 liraya ulaştı. Bir sonraki genel kurul toplantısı 15 Ekim saat 14.30'da Ankara'da yapılacak."

- **Groq Whisper Large v3** (0.375 sn):
  - Deşifre: "Şirketin 2026 yılı ilk çeyrek net karı %18 artışla 350.500 liraya ulaştı. Bir sonraki genel kurul toplantısı 15 Ekim saat 14.30'da Ankara'da yapılacak."
  - WER: %10.34 | CER: %6.96 | TR Harf: %92.31

- **Groq Whisper Large v3 Turbo** (0.249 sn):
  - Deşifre: "Şirketin 2026 yılı ilk çeyrek net karı %18 artışla 350.500 liraya ulaştı. Bir sonraki genel kurul toplantısı 15 Ekim saat 14.30'da Ankara'da yapılacak."
  - WER: %10.34 | CER: %6.96 | TR Harf: %92.31

- **Gemini (gemini-3.6-flash)** (3.955 sn):
  - Deşifre: "Şirketin 2026 yılı ilk çeyrek net kârı %18 artışla 350.500 liraya ulaştı. Bir sonraki genel kurul toplantısı 15 Ekim saat 14.30'da Ankara'da yapılacak."
  - WER: %6.9 | CER: %6.33 | TR Harf: %92.31

### Aglütinatif Morfoloji & Bağlaçlar (`05_morfoloji_ve_ekler`)

- **Referans (Ground Truth):** "Onların da bu konuda çekinceleri varmış fakat bizim netleştiremediklerimizden dolayı henüz kesin bir karar veremediler. Sen de bizimle gelecek misin?"

- **Groq Whisper Large v3** (0.366 sn):
  - Deşifre: "Onların da bu konuda çekinceleri varmış fakat bizim netleştiremediklerimiz dolayı henüz kesin bir karar veremediler. Sen de bizimle gelecek misin?"
  - WER: %5.0 | CER: %2.04 | TR Harf: %100.0

- **Groq Whisper Large v3 Turbo** (0.232 sn):
  - Deşifre: "Onların da bu konuda çekinceleri varmış fakat bizim netleştiremediklerimiz dolayı henüz kesin bir karar veremediler. Sen de bizimle gelecek misin?"
  - WER: %5.0 | CER: %2.04 | TR Harf: %100.0

- **Gemini (gemini-3.6-flash)** (3.66 sn):
  - Deşifre: "Onlerin da bu konuda çekinceleri varmış fakat bizim netleştiremediklerimiz dolayı henüz kesin bir karar veremediler. Sen de bizimle gelecek misin?"
  - WER: %10.0 | CER: %3.4 | TR Harf: %85.71

