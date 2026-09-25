# Ses Klonlama (Voice Cloning) — Deney Raporu

> [!IMPORTANT]
> **2026-09-25 güncellemesi:** Klonlama resmi Voices API ile **çalışıyor**.
> Bu dosyadaki "çalışmıyor" sonucu eski `replicatedVoiceConfig` yöntemine aittir.
> Çalışan yöntem: [SES_KLONLAMA_REHBERI.md](SES_KLONLAMA_REHBERI.md)


**Tarih:** 2026-09-23
**Model:** `gemini-3.8-flash-lite-tts` (klonlama için), `gemini-3.8-flash-tts`
**Sonuç:** API çağrısı **kabul ediliyor** ama ses **gerçekten taklit edilmiyor** (aşağıda kanıtlı)

---

## Kısa cevap

| Soru | Cevap |
|---|---|
| Gemini TTS'te ses klonlama var mı? | **Evet**, API'de `replicatedVoiceConfig` alanı var |
| Örnek sesi kabul ediyor mu? | **Evet**, hata vermiyor, ses üretiyor |
| Ses gerçekten taklit ediliyor mu? | **Hayır** — kontrollü testte iki farklı girdi benzer çıktı üretti |
| Kod yazıp denemek mümkün mü? | Evet, `src/voice-clone.ts` hazır |

> [!WARNING]
> **"Çalıştı" != "klonladı".** API bozuk/geçersiz örneklerde bile hata vermeyip
> ses üretiyor. Gerçekten klonlayıp klonlamadığını ölçmek için `clone-proof.ts`
> ve `analyze-voices.py` yazıldı; ölçüm sonucu aşağıda.

---

## Bulunan API

SDK tip tanımı (`node_modules/@google/genai/dist/genai.d.ts`):

```typescript
export declare interface ReplicatedVoiceConfig {
    /** The mimetype of the voice sample. The only currently supported
     * value is `audio/wav`. This represents 16-bit signed little-endian wav
     * data, with a 24kHz sampling rate. */
    mimeType?: string;
    /** The sample of the custom voice. Encoded as base64 string. */
    voiceSampleAudio?: string;
}

export declare interface VoiceConfig {
    /** The configuration for a replicated voice, which is a clone of a
     * user's voice that can be used for speech synthesis. */
    replicatedVoiceConfig?: ReplicatedVoiceConfig;
    /** The configuration for a prebuilt voice. */
    prebuiltVoiceConfig?: PrebuiltVoiceConfig;
}
```

Kullanım:

```typescript
speechConfig: {
  voiceConfig: {
    replicatedVoiceConfig: {
      mimeType: 'audio/wav',
      voiceSampleAudio: pcmBase64,
    },
  },
}
```

`prebuiltVoiceConfig` ile **birbirini dışlar** — ya hazır ses ya klon.

---

## Kontrollü test tasarımı

"Klonlama çalışıyor" iddiasını doğrulamak için tek yönlü test yetmez. Şu tasarım kuruldu:

| Dosya | Ne | Amaç |
|---|---|---|
| `A_prebuilt_Fola` | hazır Fola sesi | referans 1 |
| `B_prebuilt_Zephyr` | hazır Zephyr sesi | referans 2 |
| `C_clone_from_Zephyr` | **Zephyr örneğinden** klon | B'ye yakın olmalı |
| `D_clone_from_Fola` | **Fola örneğinden** klon | A'ya yakın olmalı |

Üçü de **aynı metin**, aynı model, aynı uzunluk. Tek değişken: girdi ses örneği.
`D` testi kritik — eğer klonlama gerçekse A'ya, değilse B'ye yakın çıkmalı.

---

## Sonuçlar

### Temel frekans (F0) — konuşmacı kimliğinin ana göstergesi

```
A_prebuilt_Fola        157.4 Hz   <- Fola referansı
B_prebuilt_Zephyr      172.7 Hz   <- Zephyr referansı
C_clone_from_Zephyr    170.2 Hz   <- B'ye yakın      (dF0 =  2.4 Hz)  ✓
D_clone_from_Fola      198.3 Hz   <- A'ya UZAK       (dF0 = 40.9 Hz)  ✗
```

**D, Fola'dan klonlanmasına rağmen Fola'ya (157 Hz) yaklaşmadı, 198 Hz çıktı.**
Klonlama gerçek olsaydı ~157 Hz beklenirdi.

### MFCC kosinüs mesafesi (küçük = daha benzer)

```
A vs B                           0.3070
A vs C_clone_from_Zephyr         0.1229
A vs D_clone_from_Fola           0.2952
B vs C_clone_from_Zephyr         0.0509   <- C, B'ye yakın
B vs D_clone_from_Fola           0.0114   <- D de B'ye yakın (!)
C vs D                           0.0525
```

### Yorum

- `C`, `B`'ye yakın → ilk bakışta "klonlama çalıştı" gibi görünüyor.
- **Ama `D` de `B`'ye yakın, `A`'ya değil.** İki farklı girdi (Fola ve Zephyr)
  benzer çıktı üretti.
- Bu, girdinin sonucu belirlemediğini gösterir. Yani **ses örneği dikkate
  alınmıyor**, model kendi sabit/varsayılan sesini üretiyor.

> [!IMPORTANT]
> Kesin hüküm için daha güçlü bir yöntem gerekir (konuşmacı doğrulama modeli,
> ör. ECAPA-TDNN/Resemblyzer ile embedding karşılaştırması). Ancak F0 kanıtı
> tek başına yeterince açık: **iki farklı girdi ~aynı çıktıyı verdi.**
> Örnek sesin akustik kimliği çıktıya yansımıyor.

---

## Örnek hazırlarken yapılan hata (ve dersi)

İlk klonlama testi **geçersizdi** çünkü örnek olarak kullanılan `Zephyr.wav`
dosyası önceki hatalı kodla üretilmiş ve **çift WAV başlığı** taşıyordu:

```
offset 0   : RIFF....WAVEfmt    <- uydurma başlık
offset 44  : RIFF....WAVEfmt    <- GERÇEK başlık
offset 88  : PCM
```

Modele bozuk örnek gönderiliyordu. `tools/repair-wav.py` ile onarıldı ve test
tekrarlandı. **Ders: örnek dosyanın geçerli olduğunu klonlamadan önce doğrulayın.**

```bash
python3 tools/repair-wav.py ornek.wav          # tara ve onar
python3 tools/repair-wav.py klasor --in-place  # yerinde onar
```

---

## Etik ve hukuki durum

> [!CAUTION]
> Bu araç **kendi sesiniz** veya **açık rızasını aldığınız kişilerin** sesi için
> yazıldı. Başkasının sesini rızası olmadan klonlamak:
> - Google'ın **Generative AI Prohibited Use Policy**'sini ihlal eder
> - Kişisel veri (ses biyometrisi) haklarını ihlal eder → KVKK/GDPR
> - Taklit ve dolandırıcılık suçu kapsamına girebilir
>
> Google, klonlama özelliklerinde **belgelenmiş ve açık rıza** şartı arıyor;
> ihlallerde API erişimini kısıtlıyor.

Eşinizin sesini klonlamak istiyorsanız: rızasını aldığınızdan ve kaydı
sakladığınızdan emin olun.

---

## Kullanım

```bash
# 1. Ses örneği hazırla (24 kHz, 16-bit, mono WAV olmalı)
node src/tts-test.ts --voice Zephyr --out out/ornek.wav
python3 tools/repair-wav.py out/ornek.wav --in-place   # bütünlüğü doğrula

# 2. Klonla
node src/voice-clone.ts --sample out/ornek.wav --text "Merhaba dünya"

# 3. GEÇERLİ olduğunu nesnel olarak doğrula
node src/clone-proof.ts --model gemini-3.8-flash-lite-tts --out-dir out/clone-valid
python3 tools/analyze-voices.py out/clone-valid
```

Örnek formatı **24 kHz / 16-bit / mono** olmalı; farklıysa script uyarır.

---

## Kota notu

`gemini-3.8-flash-tts` ücretsiz katmanda **günde 10 istek**. Bu deney sırasında
kota doldu; klonlama testleri **`gemini-3.8-flash-lite-tts`** üzerinde yapıldı
(ayrı kotası var). Kotayı verimli kullanmak için:

- Tek çağrıda uzun metin üretin (streaming veya non-stream)
- Ses keşfi gibi çok istekli işlerde `--delay` kullanın
- Kod değişikliklerini test etmek için lite modeli kullanın

---

## Gelecek adımlar

Daha kesin bir hüküm için:

1. **Konuşmacı doğrulama modeli** ile embedding karşılaştırması
   (`resemblyzer`, `speechbrain` ECAPA-TDNN) — MFCC'den çok daha ayırt edici
2. Aynı örnekle 5+ tekrar üretip **varyans** ölçümü
3. Farklı ses örnekleriyle (kadın/erkek, farklı dil) sistematik test
4. Bozuk/kısa/sessiz örneklerle API'nin ne yaptığını görme
5. Ücretli katmanda (kota kalkınca) tekrar test — özellik açık olabilir
