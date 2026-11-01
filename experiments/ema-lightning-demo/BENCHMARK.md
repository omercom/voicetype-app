# Apple M5 — EMA Lightning hız ölçümü

Tarih: 7 Ekim 2026. Cihaz: Apple M5, 16 GB RAM, macOS 27.0.
EMA Lightning 1.0.1, PyTorch 2.14.1, Python 3.12.13.
4 CPU iş parçacığı; seed 0; 48 kHz ses; her metin için ısınma sonrası 5 tekrar.
CPU ve MPS ölçümleri sırayla ve çevrimdışı çalıştırıldı.
WAV yazma ve ses çalma ölçüm dışında kaldı.

| Metin | Ses süresi | CPU üretim | CPU ilk parça | MPS üretim | MPS ilk parça | MPS gerçek zaman çarpanı |
|---|---:|---:|---:|---:|---:|---:|
| Merhaba / VoiceType | 5,36 sn | 164,9 ms | 50,4 ms | 48,1 ms | 27,8 ms | 111,4× |
| Toplantı / saat | 5,16 sn | 156,6 ms | 50,3 ms | 48,4 ms | 26,2 ms | 106,6× |
| Dikteyi dinleyerek kontrol | 9,36 sn | 314,2 ms | 71,6 ms | 74,3 ms | 30,7 ms | 126,0× |

Değerler medyandır; yalnızca bu üç metni ve cihazı temsil eder.
**9,36 saniyelik sesin tamamı MPS ile yaklaşık 74 ms’de hazırlandı.**
İlk parça gecikmesi hoparlörden duyulma gecikmesi değildir.
Demo ölçüm sonunda dosyaları çalar; canlı akış oynatmaz.

## Başlangıç maliyeti

Son çevrimdışı ölçümde CPU: Python paketlerini yükleme 697 ms, model yükleme 75 ms, ilk üretim 190 ms.
MPS: Python paketlerini yükleme 443 ms, model yükleme 146 ms, ilk üretim 678 ms.
Python sürecinin başlatılması ve komut sarmalayıcısı bu değerlere dahil değildir.
İlk kurulumda görülen ilk üretim CPU’da 7,16 sn, MPS’de 4,39 sn sürdü.
İlk indirme, ilk normalizasyon ve GPU hazırlığı kararlı üretimden daha uzun sürebilir.
Yeni metin boyutları MPS’de ek hazırlık maliyeti gösterebilir.
Bu nedenle ürün entegrasyonunda tek model örneği ve önceden ısınmış kalıcı süreç gerekir.

## Tekrar çalıştırma

```bash
./experiments/ema-lightning-demo/run.sh --offline --device cpu --runs 5 --output experiments/ema-lightning-demo/output/cpu
./experiments/ema-lightning-demo/run.sh --offline --device mps --runs 5 --output experiments/ema-lightning-demo/output/mps --play
```

Ham tekrarlar: [CPU JSON](benchmark-cpu.json), [MPS JSON](benchmark-mps.json).
Çıktılardaki metinler demo metinleridir; özel kullanıcı metinleri değildir.
8 demo testi ve 21 mevcut benchmark testi geçti.
Üç MPS WAV dosyası `afplay` ile başarıyla çalındı; dinleyici de demo sesini doğruladı.
Swift kaynakları değişmedi; bu çalışma için Swift derlemesi çalıştırılmadı.

Model kartındaki 3,86 ms / 440× değerleri RTX 4090 ve CUDA optimizasyonları içindir.
Bu değerler Mac ölçümü değildir; burada doğrudan ölçülen değerler raporlandı.
