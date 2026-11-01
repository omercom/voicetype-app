# EMA Lightning — Türkçe ses demosu

Bu deney [EMA Lightning](https://huggingface.co/canberkkkkkk/ema-lightning) modelini karşılaştırma için korur.
Model **metni sese çevirir (TTS)**; konuşmayı yazıya çevirmez (STT).
Swift uygulaması artık [Antalia Mini](../antalia-mini-demo/README.md) kullanır; dikte sağlayıcıları değişmez.
Bu eski demo kurulum paketine dahil değildir; ayrı Python sürecinde çalışır.

## Nerede kullanabiliriz?

- Dikte sonucunu sesli okuyarak hata kontrolü yapmak.
- Kullanıcının seçtiği metinden Türkçe WAV üretmek.
- İsteğe bağlı sesli bildirimler veya erişilebilirlik desteği sunmak.
- Deneylerde kullanılacak Türkçe ses örnekleri üretmek.

İlk bağlantı pano üzerinden çalışır: VoiceType ile yazdığınız metni kopyalayıp `--clipboard` kullanın.
Demo panoyu yalnızca bu seçenek verildiğinde okur; değiştirmez.
Uygulamada **⌥⌘S**, **Metni Seslendir** menüsü ve **Servisler → VoiceType ile Seslendir** kullanılabilir.
Motoru proje kökünden `./setup-tts.sh` ile kurun; uygulamayı `./install.sh` ile güncelleyin.
Uygulama ayrı, kalıcı bir Antalia Mini sürecini ısıtır ve ilk kurulumdan sonra çevrimdışı çalışır.
Yeni dikte başlamadan önce seslendirmeyi durdurur. Dikte sırasında yeni okuma başlamaz.
Otomatik dikte sonucu okuma eklenmedi; seslendirme açık kullanıcı komutuyla başlar.

## Çalıştırma

Gereksinimler: [uv](https://docs.astral.sh/uv/getting-started/installation/) ve modelin ilk indirilmesi için internet.
Komutlar proje kökünden çalışır; Python 3.12 ve kilitli bağımlılıklar otomatik kurulur.

```bash
# Apple Silicon GPU ile üç örnek üret, ölç ve dinlet
./experiments/ema-lightning-demo/run.sh --device mps --play

# Kendi metnin
./experiments/ema-lightning-demo/run.sh --device mps --text "Merhaba, bugün hava çok güzel." --play

# Panodaki dikte sonucunu oku
./experiments/ema-lightning-demo/run.sh --device mps --clipboard --play

# UTF-8 dosya oku
./experiments/ema-lightning-demo/run.sh --file metin.txt --play

# İlk indirmeden sonra yalnızca yerel önbelleği kullan
./experiments/ema-lightning-demo/run.sh --device mps --offline --play

# CPU ile karşılaştır
./experiments/ema-lightning-demo/run.sh --device cpu --threads 4 --runs 5

# Model indirmeden birim testleri
python3 -m unittest discover -s experiments/ema-lightning-demo -p 'test_*.py' -v
```

Varsayılan cihaz `cpu`; MPS deneysel seçenek olarak açıkça seçilir.
Bu Mac’in Apple M5 GPU’sunda MPS ile üretim doğrulandı.
Diğer Mac’lerde destek veya performans farklı olabilir; gerekirse CPU kullanın.
CUDA seçeneği NVIDIA GPU gerektirir; `.lightning()` yalnızca CUDA yolunda çağrılır.

## Çıktılar ve ölçüm

- `output/demo-01.wav` ve diğer WAV dosyaları: mono, 48 kHz, 16-bit PCM.
- `output/benchmark.json`: başlangıç, ilk üretim, ısınma ve bütün tekrarların ölçümleri.
- `--output` ile ayrı sonuç klasörleri seçilebilir; aynı klasörün dosyaları yeniden yazılır.
- `say` süresi bütün sesi üretme süresidir; `stream` ilk parça süresi ayrı ölçülür.
- İlk parça süresi hoparlörden duyulma süresi değildir.
- Demo WAV dosyalarını ölçüm bittikten sonra çalar; canlı akış oynatıcısı değildir.
- Her metin için ısınma yapılır; rapor tekrarların medyanını verir.
- RTF = üretim süresi / ses süresi. Gerçek zaman çarpanı bunun tersidir.

Python başlatma, model yükleme ve ilk isteğin maliyeti ısınmış hızdan ayrıdır.
Özellikle MPS yeni metin boyutlarında da ek hazırlık süresi gösterebilir.
[Apple M5 ölçüm sonuçları](BENCHMARK.md) CPU ve MPS karşılaştırmasını içerir.
Model kartındaki RTX 4090 sonucu Mac için geçerli değildir.

## Sınırlar ve gizlilik

Tek Türkçe ses vardır; ses klonlama ve duygu kontrolü yoktur.
Yabancı sözcüklerin ve sayıların telaffuzunu dinleyerek kontrol edin.
Bu sesler yapay zekâ ile üretilmiştir; paylaşırken bunu belirtin.
Model kodu ve ağırlıkları Apache-2.0 lisanslıdır; yeniden dağıtımda lisans koşulları geçerlidir.
İlk kurulum paketleri ve model ağırlıklarını indirir; metin bulut TTS servisine gönderilmez.
`--offline` Hugging Face indirmelerini kapatır; eksik ağırlık varsa işlem başarısız olur.
Metinler WAV ve JSON çıktısında yerelde saklanır; özel metinleri paylaşmayın.
`output/` ve `.venv/` Git dışında tutulur.
