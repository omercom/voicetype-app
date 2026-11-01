# Antalia Mini — Türkçe TTS

VoiceType artık [Antalia Mini](https://huggingface.co/cloud0day3/antalia-mini) kullanır.
Dikte sağlayıcıları değişmez. Eski EMA deneyi karşılaştırma için korunur.

- Paket: `antalia-mini[hub]==1.0.0`, Python 3.12, PyTorch 2.14.1.
- Model revizyonu: `1e8166a7436f3e11f7f03b339258ec30f366db60`.
- Tek Türkçe yapay erkek sesi; ses klonlama yoktur.
- 7,62 milyon parametre; akustik model ve vocoder ağırlıkları toplam yaklaşık 30,5 MB.
- WAV: mono, 48 kHz, PCM16. Kod ve ağırlıklar Apache-2.0 lisanslıdır.

## Kurulum ve kullanım

[uv](https://docs.astral.sh/uv/getting-started/installation/) ve ilk indirmede internet gerekir.
Komutları proje kökünden çalıştırın:

```sh
# Kullanıcı motorunu kur; uygulamayı güncelle
./setup-tts.sh
./install.sh

# Sekiz test metnini ölç ve dinlet
./experiments/antalia-mini-demo/run.sh --device mps --runs 5 --play

# Kendi metnini dinlet
./experiments/antalia-mini-demo/run.sh --device mps --offline --text "Merhaba, bugün hava çok güzel." --play

# Panoyu yalnız bu seçenekle oku
./experiments/antalia-mini-demo/run.sh --device mps --clipboard --play

# CPU karşılaştırması
./experiments/antalia-mini-demo/run.sh --device cpu --threads 2 --runs 5 --output experiments/antalia-mini-demo/output/cpu

# Model indirmeden birim testleri
python3 -m unittest discover -s experiments/antalia-mini-demo -p 'test_*.py' -v

# Gerçek motor dahil uygulama testleri
VOICETYPE_TEST_ANTALIA=1 swift test
```

Demo ayrıca `--file` ve `--output` seçeneklerini destekler. Seed sabit olarak 0 kullanılır.
Varsayılan cihaz CPU'dur. Apple Silicon GPU için MPS seçin.
Uygulama MPS başlangıç hatasında CPU'ya geçer; demo bunu otomatik yapmaz.

## Ölçümler ve gizlilik

[Apple M5 ölçüm raporu](BENCHMARK.md) sekiz metnin CPU ve MPS sonuçlarını içerir.
Demo çıktıları `output/` altında WAV ve JSON olarak saklanır; bu klasör git tarafından dışlanır.
JSON özgün metni ve normalleştirilmiş metni içerir. Özel metinlerle üretilen çıktıları paylaşmayın.

Ölçüm raporunda her metin için ısınmadan sonra beş tekrarın medyanı alındı.
Demo varsayılan olarak üç tekrar yapar; `--runs` tekrar sayısını değiştirir.
Tam ses üretimi ve akışın ilk parçası ayrı ölçülür; dosya yazımı ölçüme dahil değildir.
İlk parça süresi hoparlörden duyulma süresi değildir.
Uygulama canlı akış kullanmaz; yaklaşık 350 karakterlik bölümleri sırayla üretip çalar.

Kurulum modeli indirir. Uygulama yalnız yerel, revizyonu sabit önbelleği açar.
Eksik önbellekte ağ indirmesi yapmaz; kurulum hatası gösterir.
Uygulama metni günlüğe yazmaz. Geçici WAV dosyaları bitişte veya iptalde temizlenir.
Demo kalıcı örnek üretir; bu dosyaları kendiniz silin.

Sesler yapay zekâ ile üretilmiştir. Paylaşırken bunu belirtin.
Sayıları, özel adları ve yabancı sözcükleri dinleyerek kontrol edin.
Teknik WAV kontrolü telaffuz veya doğallık ölçümü değildir.
