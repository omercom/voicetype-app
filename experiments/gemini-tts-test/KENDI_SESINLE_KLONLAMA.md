# Kendi Sesinle Klonlama — Deney Sonuçları

> [!IMPORTANT]
> **2026-09-25 güncellemesi:** Klonlama resmi Voices API ile **çalışıyor**.
> Bu dosyadaki "çalışmıyor" sonucu eski `replicatedVoiceConfig` yöntemine aittir.
> Çalışan yöntem: [SES_KLONLAMA_REHBERI.md](SES_KLONLAMA_REHBERI.md)


**Tarih:** 2026-09-23
**Denek:** Omer'in kendi sesi (24.6 sn kayıt)
**Modeller:** `gemini-3.8-flash-tts` (asıl hedef), `gemini-2.5-flash-preview-tts` (yedek)

---

## KISA CEVAP

| Soru | Cevap |
|---|---|
| Kayıt hattı kuruldu mu? | ✅ Evet, çalışıyor |
| Sesiniz kaydedildi mi? | ✅ 24.6 sn, kaliteli |
| Klonlama çağrısı kabul edildi mi? | ✅ Evet |
| Ses gerçekten sizin sesiniz gibi mi? | ❌ **Hayır** — hazır sese daha yakın |
| `gemini-3.8-flash-tts` ile test edildi mi? | ❌ Kota doldu, yarın |

---

## 1. Kayıt hattı (kuruldu ve çalışıyor)

```
tools/record-voice.py     -> mikrofon kaydı + canlı seviye çubuğu
tools/inspect-recording.py -> "gerçekten konuşma var mı?" teşhisi
tools/prepare-sample.py   -> 24kHz/16-bit/mono'ya çevir + kalite ölç
tools/compare-voices.py   -> cepstrum tabanlı F0 + MFCC ile karşılaştır
```

### Karşılaşılan sorun: giriş kazancı düşüktü

İlk kayıt **çok sessiz** çıktı (tepe -24.3 dB). Teşhis:

```
sistem giriş ses seviyesi: 27/100     <- çok düşük (75-100 olmalı)
konuşma bandı            : %99.0      <- konuşma VARDI, sadece zayıftı
spektral merkez          : 379 Hz     <- insan sesi aralığı
```

**Çözüm:** giriş seviyesi 80'e çıkarıldı. `record-voice.py` artık kayıt öncesi
bunu otomatik kontrol edip düşükse yükseltiyor.

> [!TIP]
> macOS'ta giriş seviyesini kontrol edin:
> ```bash
> osascript -e "get volume settings"
> osascript -e "set volume input volume 80"
> ```

---

## 2. Sesinizin akustik profili

| Ölçüm | Değer | Yorum |
|---|---|---|
| Süre | 24.6 sn | ideal (10-30 sn) |
| **F0 (perde)** | **150.0 Hz** | kalın/erkek aralığı |
| SNR | ~13-14 dB | kullanılabilir (ideal 20+) |
| Gürültü | geniş bantlı | fan/oda gürültüsü, elektrik hum yok |
| Klip | %0 | bozulma yok |

Gürültü spektrumu geniş bantlı (belirgin 50/60 Hz hum yok) → sessiz odayla
iyileştirilebilir ama klonlamayı engellemez.

---

## 3. Klonlama sonucu — **çalışmadı**

### Test tasarımı

```
A_my_voice        -> sizin gerçek kaydınız (referans)
B_prebuilt_Kore   -> hazır Kore sesi, aynı metin
D_prebuilt_Puck   -> hazır Puck sesi, aynı metin
C_clone_myvoice   -> SİZİN sesinizden klonlanan çıktı
```

Model: `gemini-2.5-flash-preview-tts` (3.8 kotası doluydu)

### Ölçümler (cepstrum F0 + MFCC)

| Dosya | F0 |
|---|---|
| A: sizin sesiniz | **150.0 Hz** |
| B: hazır Kore | 183.2 Hz |
| D: hazır Puck | 109.3 Hz |
| **C: klonlanan çıktı** | **205.1 Hz** |

### MFCC mesafesi (küçük = benzer)

```
C vs B_prebuilt_Kore      0.0209   <- EN YAKIN
C vs D_prebuilt_Puck      0.0385
C vs A_my_voice           0.0546   <- KENDİ SESİNİZ EN UZAK
```

> [!IMPORTANT]
> **Klonlanan çıktı (205.1 Hz), sizin sesinize (150.0 Hz) 55 Hz uzak; hazır Kore
> sesine (183.2 Hz) ise sadece 22 Hz uzak.**
>
> MFCC'de de aynı: çıktı, sizin sesinize **en uzak**, hazır seslere **daha yakın**.
> Yani model sizin sesinizi değil, kendi varsayılan sesini üretti.

### Bu, önceki deneyi doğruluyor

`Fola`/`Zephyr` ile yapılan önceki testte de aynı örüntü çıkmıştı: **ters testte
(D dosyası) çıktı, kaynağa değil diğer hazır sese yakın** çıkmıştı.
Şimdi gerçek insan sesiyle de aynı sonuç: **klonlama girdiyi dikkate almıyor.**

---

## 4. Neden çalışmadı? (olası nedenler)

| Olası neden | Değerlendirme |
|---|---|
| Model klonlamayı desteklemiyor | **Muhtemel** — 2.5 ailesi `Fola`'yı bile reddediyor |
| Özellik hesapta açık değil | Muhtemel — API hata vermiyor ama sessizce yok sayıyor |
| Örnek formatı uyumsuz | **Değil** — 24kHz/16-bit/mono doğrulandı |
| Örnek kalitesi düşük | Kısmen — SNR 13 dB, ama bu kadar fark yaratmaz |
| Rıza (consent) doğrulaması eksik | Mümkün |
| **Örnek izlenmiyor, varsayılana düşülüyor** | **En olası** |

---

## 5. Sıradaki adımlar (kota açılınca)

```bash
# 1. 3.8-flash-tts kotasının açılmasını bekleyin (günlük 10 istek, 00:00 Pasifik)
# 2. Simetrik testi çalıştırın - ARTIK DOĞRU TASARIM:
node src/clone-proof.ts --model gemini-3.8-flash-tts --out-dir out/clone-sym
python3 tools/compare-voices.py out/clone-sym
```

Beklenen (klonlama çalışıyorsa):
```
C_clone_from_Zephyr  ->  B_prebuilt_Zephyr'e yakın
D_clone_from_Fola    ->  A_prebuilt_Fola'ya yakın
```

> [!WARNING]
> Gerçek karar bu testten çıkacak. 2.5 ile alınan sonuç **kesin değil** çünkü
> o model klonlamayı hiç desteklemiyor olabilir. 3.8-flash-tts ile aynı test
> yapılmadan "klonlama Gemini'de çalışmıyor" denemez.

Ek testler:
- Kendi sesinizden `gemini-3.8-flash-tts` ile klon üretip, sizin kaydınızla
  doğrudan karşılaştırma (en ayırt edici test)
- Örnek uzunluğunun etkisi (5 sn / 15 sn / 30 sn)
- Sessiz oda kaydı ile SNR'ı 20+ dB'ye çıkarma

---

## 6. Ölçüm aracı hakkında önemli not

Bu deney sırasında **F0 ölçümündeki bir hata bulundu ve düzeltildi**:

> [!CAUTION]
> İlk kullanılan otokorelasyon yöntemi **oktav hatası** yapıyordu: F0'i sürekli
> 2x/3x gösteriyordu (400 Hz üst sınıra dayanıyordu). Bu, önceki raporlardaki
> F0 değerlerini **güvenilmez** kılıyor.
>
> Düzeltilmiş sürüm **cepstrum** tabanlı ve sentetik testte 4/4 tam isabet
> sağlıyor (110/150/200/250 Hz → tam doğru).
>
> Ayrıca `voiced()` ön-işleme fonksiyonu, büyük bir diziye cepstrum uygulayıp
> sonuçları bozuyordu (tüm dosyalar 93.8 Hz'e kilitleniyordu). Kaldırıldı.

Sonuç: **bu rapordaki F0 ve MFCC değerleri doğrulanmış araçla üretildi.**

---

## 7. Etik

> [!CAUTION]
> Bu deney **kendi sesinizle** yapıldı. Başkasının sesini (eş, arkadaş, ünlü)
> rızası olmadan klonlamak: Google Prohibited Use Policy ihlali, KVKK/GDPR
> kişisel veri ihlali, ve taklit/dolandırıcılık suçu kapsamına girer.
> Açık rıza alın ve kaydını saklayın.
