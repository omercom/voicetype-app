# Kendi Sesini Klonlama — Çalışan Yöntem

**Tarih:** 2026-09-25
**Durum:** ✅ Çalışıyor — resmi Voices API ile
**Ses kimliği:** `voice_snw1ur9attln` ("Omer", tr-TR, bitiş 2027-09-25)

> Bu rehber, `VOICE_CLONING.md` ve `KENDI_SESINLE_KLONLAMA.md` dosyalarındaki
> "klonlama çalışmıyor" sonucunu **geçersiz kılar**. O denemeler resmi olmayan
> eski yöntemi (`replicatedVoiceConfig`) kullanıyordu.

---

## Sonuç (ölçüm)

| Ses | Perde (F0) | Senin sesine MFCC mesafesi |
|---|---|---|
| Gerçek ses (`myvoice_v3_clean.wav`) | 128.0 Hz | – |
| **Resmi klon** | **132.6 Hz** | **0.0125** |
| Eski yöntemle klon | 206.9 Hz | 0.0526 |
| Hazır Puck | 150.9 Hz | 0.1877 |
| Hazır Kore | 189.0 Hz | 0.2206 |

Karşılaştırma dosyaları: `out/official/` → `python3 tools/compare-voices.py out/official`

---

## Hızlı kullanım

```bash
cd experiments/gemini-tts-test

# Kendi sesinle okut (varsayılan model: Flash Lite, ses: out/voice-id.txt)
node src/speak.ts --text "Merhaba, bu benim sesim." --play
node src/speak.ts --model gemini-3.8-flash-tts --text-file metin.txt --out out/okuma.wav

# Kayıtlı seslerini gör / sil
node src/list-voices.ts
node src/list-voices.ts --all --lang tr-TR     # Google'ın hazır Türkçe sesleri
node src/list-voices.ts --delete voice_xxx
```

---

## Yeni ses oluşturma (adım adım)

### 1. Referans kaydı (10–30 sn)
Sessiz oda, mikrofona 15–20 cm, doğal ve kesintisiz konuşma.
```bash
python3 tools/record-voice.py --seconds 30 --out out/myvoice.wav
python3 tools/prepare-sample.py out/myvoice.wav --out out/myvoice_clean.wav   # 24 kHz mono 16-bit
```

### 2. Onay kaydı — aynı mikrofon, aynı oda
Bu cümle **kelimesi kelimesine** okunmalı (tr-TR):

> **Bu sesin sahibi benim ve Google'ın bu sesi kullanarak sentetik bir ses modeli oluşturmasına izin veriyorum.**

```bash
python3 tools/record-voice.py --seconds 15 --out out/consent_raw.wav
python3 tools/prepare-sample.py out/consent_raw.wav --out out/consent_clean.wav --no-normalize
```

### 3. Sesi oluştur
```bash
node src/create-voice.ts --source out/myvoice_clean.wav --consent out/consent_clean.wav --name "Omer"
# -> voice_... kimliği out/voice-id.txt dosyasına yazılır
# --no-store : 7 gün geçerli voicekey_... (projede saklanmaz)
```

---

## Neden önce çalışmadı? (öğrenilenler)

| Sorun | Belirti | Çözüm |
|---|---|---|
| Eski yöntem (`replicatedVoiceConfig`, her istekte örnek) | Hata yok ama ses rastgele; aynı örnek 114 Hz / 213 Hz | Resmi `POST /v1beta/voices` → kalıcı `voice_...` kimliği |
| Onay kaydı yoktu | – | Google zorunlu tutuyor |
| **Yanlış Türkçe onay cümlesi** | HTTP 500 · `The recorded phrase didn't match the text on screen` | TR doküman sayfası **makine çevirisi**; "English (US)" satırında İngilizce cümlenin çevirisi duruyor. Gerçek cümle **tr-TR** satırındaki (yukarıda) |
| `language_code` verilmedi | Aynı "didn't match" hatası | Voice nesnesine `language_code: "tr-TR"` |
| `model: gemini-3.8-flash-lite-tts` ile oluşturma | HTTP 400 · `does not support Voice Replication` | `model` alanını boş bırak; oluşan ses **tüm** TTS modelleriyle (Lite dahil) kullanılır |
| Kayıt başı kesik / sessiz | Transkriptte cümlenin yarısı | Önce mikrofonu aç, sonra ping ver; kaydı transkriptle doğrula |
| Eski SDK (`@google/genai` 1.52) | `voices` API yok | REST ile çağrılıyor (SDK 2.24+ gerekmez) |

---

## API özeti

**Oluşturma** — `POST https://generativelanguage.googleapis.com/v1beta/voices`
```json
{
  "store": true,
  "voice": {
    "type": "replicated",
    "display_name": "Omer",
    "language_code": "tr-TR",
    "replicated": {
      "source_audio":  { "mime_type": "audio/wav", "data": "<base64>" },
      "consent_audio": { "mime_type": "audio/wav", "data": "<base64>" }
    }
  }
}
```

**Kullanma** — `POST .../v1beta/models/gemini-3.8-flash-lite-tts:generateContent`
```json
{
  "contents": [{ "role": "user", "parts": [{ "text": "Merhaba" }] }],
  "generationConfig": {
    "responseModalities": ["AUDIO"],
    "speechConfig": { "voiceConfig": { "voice": "voice_snw1ur9attln" } }
  }
}
```
Yanıt: `audio/l16; rate=24000` ham PCM → `speak.ts` WAV başlığı ekler.

**Listeleme / silme** — `GET /v1beta/voices`, `DELETE /v1beta/voices/{id}`

---

## Kotalar (ücretsiz katman)

| Model | Günlük istek |
|---|---|
| `gemini-3.8-flash-lite-tts` | 10 |
| `gemini-3.8-flash-tts` | 10 |

Sıfırlanma: gece yarısı Pasifik saati. Hata: HTTP 429 `GenerateRequestsPerDayPerProjectPerModel-FreeTier`.

---

## Gizlilik ve etik

- Ses Google projesinde 1 yıl saklanır; `node src/list-voices.ts --delete <id>` ile silinir.
- Yalnızca **kendi sesin** veya **açık rızası alınmış** birinin sesi. Onay kaydı bunun kanıtıdır.
- Üretilen seslerde görünmez SynthID filigranı bulunur.

Kaynaklar:
[Ses kopyalama (TR)](https://ai.google.dev/gemini-api/docs/generate-content/voice-replication?hl=tr) ·
[Voices API](https://ai.google.dev/api/voices) ·
[TTS dokümanı](https://ai.google.dev/gemini-api/docs/speech-generation)
