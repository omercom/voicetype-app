# Antalia Mini — Apple M5 ölçümü

9 Ekim 2026; macOS 27.0 arm64, Apple M5, Python 3.12.13, PyTorch 2.14.1, Antalia Mini 1.0.0.
Model revizyonu: `1e8166a7436f3e11f7f03b339258ec30f366db60`.
İki CPU iş parçacığı, seed 0, varsayılan model ayarları ve 48 kHz ses kullanıldı.
Her metin için ısınmadan sonra beş tekrarın medyanı alındı.

| Metin | Ses süresi (sn) | CPU üretim (ms) | CPU ilk parça (ms) | MPS üretim (ms) | MPS ilk parça (ms) | MPS gerçek zaman çarpanı |
|---|---:|---:|---:|---:|---:|---:|
| 1. Merhaba / VoiceType | 6,30 | 182,9 | 105,1 | 101,1 | 65,7 | 62,3× |
| 2. Toplantı / saat | 5,76 | 211,3 | 125,3 | 95,7 | 63,6 | 60,2× |
| 3. Uzun açıklama | 11,28 | 300,0 | 116,4 | 140,9 | 67,1 | 80,0× |
| 4. Para / tarih / Dr. Ayşe | 9,02 | 207,9 | 102,6 | 114,5 | 64,0 | 78,8× |
| 5. Ö / ı / Türkçe harfler | 5,38 | 186,4 | 92,5 | 111,8 | 67,2 | 48,1× |
| 6. WhatsApp / Python / GitHub | 5,24 | 163,7 | 100,4 | 94,3 | 66,7 | 55,6× |
| 7. Kısa yanıtlar | 5,09 | 125,4 | 118,2 | 73,1 | 74,7 | 69,6× |
| 8. Uzun İstanbul paragrafı | 17,26 | 346,1 | 163,0 | 182,0 | 96,4 | 94,8× |

## Başlangıç maliyeti

MPS koşusunda paket içe aktarma 0,584 sn; model yükleme 0,217 sn; ilk tam ses üretimi 2,946 sn sürdü.
CPU koşusunda içe aktarma 5,288 sn; model yükleme 4,646 sn; ilk üretim 0,618 sn sürdü.
CPU koşusu ilk indirme sırasında yapıldı. Başlangıç süreleri doğrudan cihaz karşılaştırması değildir.
Isınmış hızlar ilk uygulama açılışının gecikmesi değildir.
Uygulama kalıcı motor sürecini önceden ısıtır.

## Doğrulama

- CPU ve MPS ile toplam 16 WAV üretildi.
- Bütün dosyalar mono, 48 kHz ve PCM16 çıktı.
- Örnekler sonlu ve sessiz değil; tepe genliği 0,6049–0,8933 aralığında çıktı.
- Üç MPS örneği `afplay` ile başarıyla çalındı.
- 441 Swift testi geçti; gerçek Antalia üretimi ve geçici dosya temizliği bu sayıya dahildir.
- 19 Antalia Python testi, 6 bağlantı Python testi ve 11 Chrome Node testi geçti.
- Eski EMA demosunun 8 testi de geçti.
- Uygulama release olarak derlendi, imza doğrulandı ve `/Applications/VoiceTyping.app` güncellendi.
- Kurulu paket yalnız Antalia worker içeriyor; uygulama ve Antalia worker süreçleri çalışıyor.

## Sonuçların sınırı

Tam üretim ve ilk akış parçası ayrı çağrılarla ölçüldü; ilk parça bazen tam üretimden uzun olabilir.
İlk akış parçası hoparlörden duyulan ilk ses değildir.
Uygulama akış API'sini kullanmaz; yaklaşık 350 karakterlik WAV bölümlerini sırayla çalar.
Dosya yazımı ve oynatma, üretim ölçümüne dahil değildir.

[Eski EMA ölçümünde](../ema-lightning-demo/BENCHMARK.md) ilk üç metnin MPS üretimi 48,1 / 48,4 / 74,3 ms idi.
Antalia bu eski kayda göre daha hızlı değildir. İki model aynı metinden farklı ses süreleri üretir.
EMA bu çalışmada yeniden ölçülmedi; karşılaştırma tarihsel kayıttır.

Telaffuz, doğallık ve hata oranı otomatik ölçülmedi. Teknik kontroller ses kalitesini kanıtlamaz.
Sonraki doğrulamada Playwright 1.64.0 ve Chromium 156.0.8078.4 ile gerçek eklenti uçtan uca testi geçti.
Gerçek tarayıcı tıklaması, okuma, duraklatma, klavyeyle devam, bölüm geçişi ve dosya temizliği kontrol edildi.
[Canlı test rehberi](../../browser-extension/e2e/README.md) bu doğrulamayı tekrar çalıştırma komutlarını içerir.

Ham tekrarlar: [CPU JSON](benchmark-cpu.json), [MPS JSON](benchmark-mps.json).
