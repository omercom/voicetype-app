# Gemini 3.8 TTS Deneyi

Bu klasör, `gemini-3.8-flash-tts` modelini izole olarak test etmek için oluşturuldu.
Ana projeden (VoiceTyping) bağımsızdır — buradaki hiçbir şey ana uygulamayı etkilemez.

## Ne bulundu (özet)

| Soru | Cevap |
|---|---|
| `gemini-3.8-flash-tts` gerçekten var mı? | **Evet.** Hesapta 61 model, 5'i TTS |
| `Fola` sesi geçerli mi? | **Evet**, 3.8 modellerinde çalışıyor |
| Ses formatı ne? | `audio/l16`, **24 kHz, mono, 16-bit PCM** |
| Streaming çalışıyor mu? | Evet, ~170+ parça |
| Türkçe destekliyor mu? | Evet — `out/turkce_fola.wav` |

### Hesaptaki TTS modelleri

```
gemini-3.8-flash-tts            <- test edilen, çalışıyor
gemini-3.8-flash-lite-tts       <- çalışıyor, daha hızlı, AYRI kotası var
gemini-3.1-flash-tts-preview
gemini-2.5-flash-preview-tts
gemini-2.5-pro-preview-tts      <- 429 (kota)
```

### Ses klonlama var mı?

**Kısa cevap:** API'de `replicatedVoiceConfig` alanı **var ve çağrıyı kabul ediyor**,
ancak kontrollü testte **ses gerçekten taklit edilmiyor** (iki farklı girdi benzer çıktı üretti).

Detaylı kanıt ve ölçümler: [VOICE_CLONING.md](VOICE_CLONING.md)

```bash
node src/voice-clone.ts --sample ornek.wav --text "Merhaba"
node src/clone-proof.ts --model gemini-3.8-flash-lite-tts --out-dir out/clone-valid
python3 tools/analyze-voices.py out/clone-valid
```

> [!WARNING]
> **"Çalıştı" != "klonladı".** API geçersiz örnekte bile hata vermeyip ses üretiyor.
> Bu yüzden `clone-proof.ts` ile nesnel doğrulama şart.
> Ayrıca: başkasının sesini **rızası olmadan** klonlamak Google politikasını ve
> kişisel veri mevzuatını ihlal eder.

### Kota sınırı

> [!IMPORTANT]
> `gemini-3.8-flash-tts` ücretsiz katmanda **günde 10 istek**. Bu deneyde kota doldu.
> Çok istek atan işler için **`gemini-3.8-flash-lite-tts`** kullanın — ayrı kotası var.

> [!NOTE]
> `Fola` sesi **2.5 ailesinde yok**. `gemini-2.5-flash-preview-tts` şu hatayı verir:
> `Voice name Fola is not supported. Allowed voice names are: achernar, achird, ...`
> Yani `Fola` kullanacaksanız 3.8 ailesinde kalmanız gerekir.

---

## Kurulum

```bash
cd experiments/gemini-tts-test
npm install
```

API anahtarı repo kökündeki `.env` dosyasından okunur (`GEMINI_API_KEY`).
Shell'de ayrıca tanımlamanıza gerek yok — `src/env.ts` bunu otomatik yükler.

---

## Kullanım

### 1. Modelleri listele

```bash
npm run models                 # sadece TTS ile ilgili olanlar
node src/list-models.ts --all  # 61 modelin tamamı
node src/list-models.ts --grep 3.8
```

### 2. TTS üret (asıl test)

```bash
# Varsayılan: Fola sesi, Türkçe örnek metin
node src/tts-test.ts

# Kendi metninizle
node src/tts-test.ts --text "Merhaba dünya"

# Dosyadan metin
node src/tts-test.ts --text-file texts/turkce-zorluk.txt

# Farklı ses / çıktı yolu
node src/tts-test.ts --voice Kore --out out/kore.wav

# Streaming yerine tek seferde (karşılaştırma için)
node src/tts-test.ts --no-stream

# Ham PCM parçalarını da diske dök (hata ayıklama)
node src/tts-test.ts --raw
```

### 3. Ses adı doğrula

```bash
node src/check-voice.ts Fola
node src/check-voice.ts Fola gemini-2.5-flash-preview-tts
```

Geçersizse, API'nin hata mesajındaki **desteklenen ses listesini** ayrıştırıp yazdırır.

### 4. Tüm sesleri keşfet

```bash
node src/discover-voices.ts                          # 3.8-flash-tts
node src/discover-voices.ts --model gemini-3.8-flash-lite-tts
node src/discover-voices.ts --delay 8000             # rate limit'e takılırsanız
```

### 5. Modelleri karşılaştır

```bash
node src/compare-models.ts --voice Fola
```

---

## Ölçülen sonuçlar

`Fola` sesi, 79 karakterlik metin:

| Model | Sonuç | Süre | Gecikme |
|---|---|---|---|
| `gemini-3.8-flash-tts` | OK | 5.65 sn | 3903 ms |
| `gemini-3.8-flash-lite-tts` | OK | 5.37 sn | 2176 ms |
| `gemini-3.1-flash-tts-preview` | HATA | — | — |
| `gemini-2.5-flash-preview-tts` | HATA (`Fola` yok) | — | — |
| `gemini-2.5-pro-preview-tts` | HATA (429 kota) | — | — |

İlk çalıştırma (streaming, 173 parça):
```
mimeType       : audio/l16; rate=24000; channels=1
parça sayısı   : 173
ses verisi     : 551.3 KB
ilk ses gecikme: 1305 ms
toplam süre    : 5739 ms
süre           : ~11.76 sn
```

---

## Orijinal koddaki düzeltilen hatalar

Size verilen örnek kodda **kritik** bir sorun vardı; bu klasördeki sürümde düzeltildi:

> [!WARNING]
> **Streaming'de her parça ayrı dosyaya yazılıyordu.**
> Orijinal kodda `for await` döngüsü içinde `fileIndex++` ile her chunk ayrı bir
> `ENTER_FILE_NAME_0.wav`, `ENTER_FILE_NAME_1.wav` ... dosyasına kaydediliyordu.
> Ama streaming'de chunk'lar **tek bir sesin parçalarıdır** — her biri WAV başlığı
> taşıyan ayrı bir dosya olarak yazılırsa, 173 adet çalınabilir ama yarım/bozuk dosya
> oluşur. Buradaki sürüm tüm PCM parçalarını birleştirip **tek bir WAV** yazar.

Diğer düzeltmeler:

1. **WAV başlığında yanlış uzunluk** — orijinalde `createWavHeader(rawData.length, ...)`
   çağrılıyordu; `rawData` bir **base64 string** olduğu için `.length` gerçek bayt
   sayısının ~1.33 katıdır. Doğrusu, base64 çözüldükten sonraki `Buffer.byteLength`.
2. **Kanal sayısı okunmuyordu** — `numChannels: 1` sabit varsayılıyordu.
   Artık mimeType'taki `channels=` parametresinden okunuyor.
3. **Örnekleme hızı varsayılanı yoktu** — `rate` parametresi gelmezse
   `options.sampleRate` `undefined` kalıp başlık bozuluyordu. 24000 varsayılanı eklendi.
4. **Zaten kodlanmış ses yeniden sarmalanıyordu** — model `audio/wav` veya `audio/mp3`
   dönerse üzerine WAV başlığı eklenip dosya bozuluyordu. Artık mimeType kontrol ediliyor.
5. **`writeFile` callback'i beklenmiyordu** — süreç dosyalar yazılmadan sonlanabiliyordu.
6. **`ENTER_FILE_NAME_`** düz metni dosya adı olarak kalıyordu.

---

## Dosya yapısı

```
experiments/gemini-tts-test/
├── src/
│   ├── env.ts              # .env yükleyici + API anahtarı doğrulama
│   ├── wav.ts              # ortak WAV/PCM yardımcıları (tek kaynak)
│   ├── list-models.ts      # hesaptaki modelleri listeler
│   ├── tts-test.ts         # ana TTS testi (streaming -> tek WAV)
│   ├── check-voice.ts      # ses adı geçerlilik kontrolü
│   ├── discover-voices.ts  # ses adlarını keşfeder, örnek üretir
│   ├── compare-models.ts   # modelleri aynı metinle karşılaştırır
│   ├── voice-clone.ts      # ses klonlama (replicatedVoiceConfig)
│   └── clone-proof.ts      # klonlamanın gerçekliğini sınayan kontrollü deney
├── tools/
│   ├── repair-wav.py       # çift WAV başlığını onarır
│   └── analyze-voices.py   # F0/MFCC ile akustik karşılaştırma
├── texts/
│   └── turkce-zorluk.txt   # Türkçe zorluk testi metni
├── VOICE_CLONING.md        # klonlama deney raporu
├── README.md
└── out/                    # üretilen sesler (git'e girmez)
```

---

## Bilinen sınırlar

- **Günlük kota**: `gemini-3.8-flash-tts` ücretsiz katmanda **günde 10 istek**.
  Bu deneyde doldu. `gemini-3.8-flash-lite-tts` ayrı kotaya sahip — yoğun
  testler için onu kullanın.
- **429 "geçersiz" demek değildir**: Rate limit ile geçersiz ses adı karıştırılırsa
  yanlış sonuç çıkar. `discover-voices.ts` bu ikisini ayrı raporlar.
- `gemini-2.5-pro-preview-tts` ücretsiz katmanda kotaya takılıyor.
- Ses adlarının tam listesi API'den kolayca alınamıyor; geçersiz bir ad verip
  hata mesajındaki listeyi okumak en pratik yol (`check-voice.ts` bunu yapar).
- **Klonlama**: çağrı kabul ediliyor ama örneğin akustik kimliği çıktıya
  yansımıyor. Kesin hüküm için konuşmacı doğrulama modeli gerekir — bkz.
  [VOICE_CLONING.md](VOICE_CLONING.md).
