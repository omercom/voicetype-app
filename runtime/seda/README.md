# Seda-v0.1 çalışma ortamı

`./setup-stt.sh`, Python 3.12 ortamını `~/.voice_typing/stt/seda/.venv` altında kurar.
Bağımlılıklar `uv.lock` ile, model `b5cf32ae4936968b284df3f1c4c79714af71e1fe` sürümüyle sabitlenmiştir.
macOS wheel'i `sherpa-onnx-core` paketini de gerektirir; ONNX Runtime kütüphanesi bu paketten gelir.

## Apple Silicon ölçümü

- Cihaz: Apple M5, 10 CPU çekirdeği.
- Tarih: 2026-10-10.
- Örnek: `experiments/benchmark/samples/01_gunluk_konusma.mp3`, 16 kHz mono PCM16 WAV'a dönüştürüldü.
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

Bu ölçümde CPU daha hızlıdır. Varsayılan motor CPU, iş parçacığı sayısı 2 olarak tutulur.
Bu sonuç diğer modeller veya tüm Apple Silicon cihazları için üstünlük garantisi değildir.
Core ML sağlayıcısı modelin tamamını GPU/Neural Engine üzerinde çalıştırdığını garanti etmez.
MPS, sherpa-onnx içinde doğrudan kullanılan bir sağlayıcı değildir.
Kalıcı işçi ikinci ve sonraki diktelerde model yükleme ve Python başlatma maliyetini kaldırır.
Swift deşifre çağrısında aynı örnekle ilk istek 1,33 saniye, sonraki iki istek 0,28 saniye sürdü.
İptal, protokol hatası, süreç kapanışı veya zaman aşımı işçiyi durdurur; sonraki istek yeni işçi açar.

## Canlı dikte

Ses 16 kHz mono PCM16 olarak, en fazla 100 ms paketlerle aynı kalıcı işçiye gönderilir.
İlk model yüklemesi sırasında paketler sıralı tamponda bekler. Ana arayüz thread'i model yüklemesini beklemez.
Ara metin HUD'a gider; nihai metin kayıt durduktan sonra hedef uygulamaya yazılır.
Model yaklaşık 0,64 saniyelik bağlam kullanır. İlk kelime için ek konuşma bağlamı gerekebilir.
Duraklamalar oturumu sıfırlamaz. Son ses paketi ve model kartındaki 1 saniyelik sessiz kuyruk işlenir.
Beam 4, RNNLM 0,6 ve LODR -0,5 ayarları canlı ve WAV yollarında aynıdır.
Canlı hata sonrası WAV aynı yerel modelle çözülür; bulut sağlayıcısı kullanılmaz.

## Doğrulama

```sh
./setup-stt.sh
VOICETYPE_TEST_SEDA=1 swift test --filter SedaTranscriberTests
# Gerçek bir 16 kHz mono PCM16 WAV ile:
VOICETYPE_TEST_SEDA=1 VOICETYPE_SEDA_SAMPLE=/absolute/path/audio.wav swift test --filter Seda
```

Model indirilmediğinde standart testler sahte yerel işçilerle çalışır; gerçek model testi açıkça etkinleştirilmelidir.
Akustik model Apache-2.0, dil modelleri CC BY-SA 4.0 lisanslıdır.
Atıflar ve veri kaynakları indirilen model kartında bulunur: https://huggingface.co/atasoglu/seda-v0.1.
