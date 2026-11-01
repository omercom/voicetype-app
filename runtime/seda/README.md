# Seda-v0.2 çalışma ortamı

`./setup-stt.sh`, Python 3.12 ortamını `~/.voice_typing/stt/seda-v0.2/.venv` altında kurar.
Bağımlılıklar `uv.lock` ile, model `62e2cc1615a63c433b6956214a548267ada5a774` sürümüyle sabitlenmiştir.
macOS wheel'i `sherpa-onnx-core` paketini de gerektirir; ONNX Runtime kütüphanesi bu paketten gelir.
Model ve bağımlılıklar yaklaşık 93 MB model dosyasıyla ayrı klasöre kurulur. Önceki `~/.voice_typing/stt/seda` kurulumu silinmez.

Modelin `balanced` akış dosyaları, CPU üzerinde beam 4 ve dil modeliyle kullanılır.
Bu uygulama v0.2'nin isteğe bağlı noktalama biçimlendiricisini ve Silero VAD'ini kurmaz.

## Önceki sürüm: Seda-v0.1 Apple Silicon ölçümü

Aşağıdaki ölçüm v0.1'e aittir; v0.2'nin hızını göstermez.

- Cihaz: Apple M5, 10 CPU çekirdeği.
- Tarih: 2026-10-10.
- Örnek: Günlük konuşma içeren bir ses kaydı, 16 kHz mono PCM16 WAV'a dönüştürüldü.
- Yöntem: Her motor için bir model yükleme ve beş deşifre; tabloda deşifre medyanı gösterilir.
- Aynı int8 akustik model, beam 4, RNNLM ve LODR ayarları kullanıldı. Tüm motorlar aynı metni üretti.

| Motor | İş parçacığı | Model yükleme | Deşifre medyanı |
|---|---:|---:|---:|
| CPU | 1 | 0,76 sn | 0,30 sn |
| CPU | 2 | 0,75 sn | 0,29 sn |
| CPU | 4 | 0,83 sn | 0,33 sn |
| CPU | 6 | 0,79 sn | 0,57 sn |
| Core ML | 1 | 3,95 sn | 0,55 sn |
| Core ML | 2 | 3,82 sn | 0,63 sn |

Bu v0.1 ölçümünde CPU daha hızlıdır. Bu sonuç v0.2 veya tüm Apple Silicon cihazları için üstünlük garantisi değildir.
Core ML sağlayıcısı modelin tamamını GPU/Neural Engine üzerinde çalıştırdığını garanti etmez.
MPS, sherpa-onnx içinde doğrudan kullanılan bir sağlayıcı değildir.
Kalıcı işçi ikinci ve sonraki diktelerde model yükleme ve Python başlatma maliyetini kaldırır.
V0.1 ile aynı örneğin Swift deşifre çağrısında ilk istek 1,33 saniye, sonraki iki istek 0,28 saniye sürdü.
İptal, protokol hatası, süreç kapanışı veya zaman aşımı işçiyi durdurur; sonraki istek yeni işçi açar.

## Canlı dikte

Ses 16 kHz mono PCM16 olarak, en fazla 100 ms paketlerle aynı kalıcı işçiye gönderilir.
İlk model yüklemesi sırasında paketler sıralı tamponda bekler. Ana arayüz thread'i model yüklemesini beklemez.
Ara metin HUD'a gider; nihai metin kayıt durduktan sonra hedef uygulamaya yazılır.
Dengeli model yaklaşık 1,28 saniyelik parçalarla çalışır. İlk kelime için ek konuşma bağlamı gerekebilir.
Duraklamalar oturumu sıfırlamaz. Son ses paketi ve resmî uygulamadaki 1,5 saniyelik sessiz kuyruk işlenir.
Beam 4, RNNLM 0,6 ve LODR -0,5 ayarları canlı ve WAV yollarında aynıdır.
Canlı hata sonrası WAV aynı yerel modelle çözülür; bulut sağlayıcısı kullanılmaz.

## Doğrulama

```sh
./setup-stt.sh
VOICETYPE_TEST_SEDA=1 swift test --filter SedaTranscriberTests
# Gerçek bir 16 kHz mono PCM16 WAV ile:
VOICETYPE_TEST_SEDA=1 VOICETYPE_SEDA_SAMPLE=/absolute/path/audio.wav swift test --filter Seda
# Aynı kaydın ham PCM16 dosyasını da vererek canlı ve WAV sonuçlarını karşılaştırın:
VOICETYPE_TEST_SEDA=1 VOICETYPE_SEDA_SAMPLE=/absolute/path/audio.wav VOICETYPE_SEDA_PCM=/absolute/path/audio.pcm swift test --filter SedaTranscriberTests/testInstalledModelLiveMatchesBatch
```

Model indirilmediğinde standart testler sahte yerel işçilerle çalışır; gerçek model testi açıkça etkinleştirilmelidir.
Seda-v0.2 model dosyaları CC BY-SA 4.0 lisanslıdır.
Atıflar ve veri kaynakları model kartında bulunur: https://huggingface.co/atasoglu/seda-v0.2.
