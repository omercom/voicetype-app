# Release benchmark kabul protokolü

Bu belge bir **ölçüm protokolüdür, gerçek benchmark sonucu değildir**. Henüz gerçek donanım kabulü iddia edilmez. `tools/release_benchmark.py` yalnızca kullanıcının sağladığı yerel metin ve süreleri değerlendirir: Python 3 stdlib, ağ/API/anahtar/üçüncü taraf paket, mikrofon, medya kontrolü veya kayıt başlatma yoktur. `run_benchmark.py` çalıştırılmaz veya import edilmez; o betik ağ üzerinden modelleri karşılaştırır, saniye cinsinden istek süresi ölçer ve transkript yayımlar. Bu süreler HUD/ilk interim/release-to-final yerine kullanılamaz.

## Bu turdaki doğrulama — 2.1 / build 10

- Seçilmiş HUD, kayıt/transkript, sessizlik, PCM, Apple lifecycle, finalization ve Gemini model kataloğu regresyonları: **35 Swift testi geçti**.
- Offline benchmark/CPU probe testleri: **21 Python testi geçti**.
- Release build, shell sözdizimi, plist ve yerel codesign doğrulaması geçti; kurulu binary paket binary'siyle `cmp` eşleşti.
- Gemini model politikası: sesli yazma için yalnızca özel transkripsiyon modelleri (`gemini-3.5-transcribe-live`, `gemini-3.5-transcribe`) listelenir ve seçilebilir. Genel amaçlı Live/Flash/Translate/TTS/image/embedding modelleri web kataloğundan ve yerleşik listeden filtrelenir; bunlar özel ASR modeli değildir.
- Web model yenileme, Gemini `models.list` üzerinden çalışır; API anahtarı loglanmaz veya diske yazılmaz. Anahtar yoksa ağ çağrısı yapılmaz, yerleşik liste korunur.
- Kurulumdan sonra kayıt başlatılmadan yapılan **10 saniyelik süreç örneklemesi**: 11 snapshot / 10 CPU aralığı; tek çekirdek CPU p50 **%0,00**, p95 **%1,043**; örneklenen maksimum RSS **74.288 KiB (~72,5 MiB)**. Apple servisleri dahil değil; aktif konuşma testi, önce/sonra karşılaştırması veya yayın kabulü değildir. Örneklem kısa ve CPU zamanı `ps` çözünürlüğüyle sınırlıdır.
- Gerçek WER, HUD görünür ilk kare, ilk interim ve release-to-final p95 ölçümleri henüz yok. **Yayın kabulü verilmedi.**

Tekrarlanabilir otomatik kontroller:

```sh
swift test --filter 'GeminiModelCatalogTests|AppleSpeechFinalizationTests|RecordingStartAndTranscriptRegressionTests|HUDTransitionTests|VoiceTypingTests/testGeminiLiveModelConfiguration'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/BenchmarkTests -p 'test_*.py' -v
```

Bu filtreler gerçek ses doğruluğu yerine deterministik regresyonları sınar; tüm proje testlerinin veya manuel donanım kabulünün geçtiği anlamına gelmez.

## Ek otomatik sağlamlık ve dağıtım kontrolü

- Genişletilmiş offline filtre: **48 Swift testi + 21 Python testi geçti**. Sentetik boost/gürültü/darbe/limiter, transkript biriktirme ve HUD geri bildirimi dahil.
- Yeni testlerde 1000 ayrı finalization oturumu: final, timeout, iptal ve teknik hata sıraları; terminal sonuç en fazla bir kez teslim edildi. 179 ardışık partial sabit final deadline'ını uzatmadı. Bunlar deterministik olay sırası testleridir; gerçek çok iş parçacıklı yarış veya ses doğruluğu testi değildir.
- Kurulu pakette `codesign -dv --verbose=4`: **VoiceTyping Local Certificate**, TeamIdentifier yok, yalnız **arm64**. Developer ID dağıtım imzası değil.
- `xcrun stapler validate /Applications/VoiceTyping.app`: **exit 65**, paket üzerinde stapled ticket yok. Bu kontrol tek başına Apple sunucularında hiç notarization yapılmadığını kanıtlamaz; mevcut paketin taşınabilir dağıtım onayı doğrulanmamıştır.
- Bu ek turda testler ve belge güncellendi; kurulu build 10 uygulama kodunu ve Gemini Transcribe-only politikasını içerir.
- Kurulu build 10'da Gemini Live modeli `gemini-3.5-transcribe-live` için gerçek WebSocket smoke testi başarılı oldu; test transkripti ekrana çıkarılmadı.

## Gerçek kayıt oturumunu hazırlama (kullanıcı tarafından)

1. Release build/commit, macOS, bilgisayar, sağlayıcı/model/sürüm, dil (`tr-TR`), mikrofon yolu, örnekleme ayarları, izinler ve tarih kaydedilsin. Her sağlayıcı/model/build için ayrı manifest ve rapor kullanılsın; farklı koşulları birleştirerek iyi ortalama üretmeyin.
2. Açık rızalı, hassas bilgi içermeyen Türkçe referans cümleleri önceden belirleyin; gerçekten söyleneni insan denetimiyle doğrulayın. Referansı model çıktısına göre değiştirmeyin. Uygulamanın nihai çıktısını `hypothesis` alanına kullanıcı açıkça aktarsın; hata/boş çıktı denemelerini atlamayın.
3. Dahili mikrofon (`dahili`), kablolu/USB/Bluetooth `headset` ve desteklenen diğer yollar **ayrı cihaz grupları** olsun. Örneğin `headset_usb` ve `headset_bluetooth` aynı grupta toplanmasın. Release kapsamındaki tüm cihazlar `devices` listesinde önceden yer alsın; eksik cihazı listeden çıkararak geçiş elde etmeyin.
4. Her cihaz × aşağıdaki sekiz kategori için farklı deneme kimlikleri planlayın. CLI minimumu smoke test için 1'dir; kabul oturumunda hücre başına en az 20, tercihen 30–50 tekrar önerilir. Küçük örneklem p95'i kararsızdır; CLI güven aralığı veya istatistiksel anlamlılık iddiası yapmaz. Isınmış/soğuk başlangıcı ayrı oturumlarda ölçün; sırayı çeşitlendirin, başarısız denemeleri koruyun.
5. Kayıt/sağlayıcı kullanımı ve varsa ağ aktarımı yalnızca kullanıcının ayrıca onayladığı manuel oturumun parçasıdır. Bu offline araç bunları gerçekleştirmez. Ses dosyaları gerekli değildir; özel oturum notları ve transkript dosyaları repoya eklenmemelidir.

| Kategori | Deneme ve beklenen gözlem |
|---|---|
| `normal` | Normal ses/tempo, Türkçe karakterler ve noktalama; eksiksiz nihai metin |
| `quiet` | Düşük ses, sabit mikrofon mesafesi; sözcük kaybını ölç |
| `fast` | Hızlı Türkçe konuşma; tekrar/kelime düşmesi kontrolü |
| `single_word` | Tek sözcük, özellikle I/İ/ı/i ve ç/ğ/ö/ş/ü |
| `pause` | Cümle içinde belirlenmiş duraklamalar; erken final veya tekrar olmaması |
| `quick_release` | Kısa sözden hemen sonra tuş bırakma; son hecenin kaybolmaması |
| `silence` | Gerçek sessizlik; reference boş, nihai hypothesis boş olmalı |
| `noise` | Konuşmasız ortam gürültüsü; reference boş, uydurma sözcük olmamalı |

`quiet` düşük sesli konuşmadır; `noise` konuşmasız gürültüdür. Gürültü altında konuşma gerekiyorsa ayrı oturum yapın. Konuşma kategorilerinde normalize edilmiş referans boş olamaz; silence/noise kategorilerinde boş olmalıdır. Eksik hypothesis, boş hypothesis ile aynı değildir: birincisi eksik kanıt, ikincisi ölçülmüş boş sonuçtur.

## Sürelerin anlamı ve önerilen hedefler

Aynı denemeye ait monoton saat farkları **milisaniye** olarak verilir. Başlangıç/bitiş tanımları oturum boyunca sabit tutulur; gözlenemeyen değer sıfırla doldurulmaz.

| JSON alanı | Ölçüm sınırları | Bağlayıcı olmayan p95 önerisi |
|---|---|---|
| `hudMs` | Kayıt tuşu olayından HUD'ın gerçekten görünür olduğu ilk kareye | 150 ms |
| `firstInterimMs` | Kayıt tuşu olayından ilk interim callback'e | 1200 ms |
| `releaseToFinalMs` | Tuş bırakmadan nihai metnin kullanıcıya hazır olduğu ana | 2000 ms |

HUD görünürlüğünü kullanıcı ayrı, izinli bir ölçümle doğrulamalıdır; yalnızca UI fonksiyonunun dönmesi ekrana çizildiğini kanıtlamaz. Sessizlik/gürültüde `releaseToFinalMs`, boş sonucun tamamlanması/idle durumuna dönme anıdır; `firstInterimMs` bu iki kategoride **uygulanamaz**, sıfır sayılmaz. Diğer tüm hücrelerde üç metrik gerekir. Interim üretmeyen sağlayıcı bu sözleşmeyle `not-ready` kalır; desteklenen release kapsamını ayrıca kararlaştırın.

WER için evrensel hedef yoktur. Ekip testten **önce** kabul yüzdesini belirlemelidir (örnekteki %10 yalnızca örnektir). Hedefler varsayılan bağlayıcı eşikler değildir; `--thresholds` ile dört eşik açıkça verildiğinde kabul kapısı olurlar. Eşit değer geçer; büyük değer başarısızdır. Sessizlik/gürültüde normalize edilmiş tek bir uydurma sözcük bile `fail` nedenidir.

## Dosya sözleşmesi

Manifest JSON nesnesi:

```json
{
  "devices": ["dahili", "headset_usb"],
  "cases": [
    {"id": "dahili-normal-001", "device": "dahili", "category": "normal", "record_latency_line": 12}
  ]
}
```

Bu kısa şema örneği eksik kapsam nedeniyle geçmez. Her cihaz için sekiz kategori zorunludur. Her tekrar ayrı ve benzersiz `id` kullanır. `record_latency_line` opsiyoneldir: kullanıcının verdiği tek log dosyasında 1 tabanlı **fiziksel satır** numarasıdır, RecordLatency kayıt sırası değildir. Aynı log satırı birden fazla denemeye atanamaz.

Speech JSONL: her satırda `id`, string `reference`, string `hypothesis` bulunur:

```jsonl
{"id":"dahili-normal-001","reference":"İyi çalışıyor.","hypothesis":"iyi çalışıyor"}
```

Latency JSON bir dizidir; her nesne tek denemenin tek süre örneğini içerir:

```json
[{"id":"dahili-normal-001","hudMs":100,"firstInterimMs":600,"releaseToFinalMs":1100}]
```

Bunlar **sentetik şema değerleridir**, gerçek ölçüm değildir. Numeric string, boolean, negatif, null, NaN ve sonsuz süreler geçerli örnek sayılmaz. Eksik/geçersiz metrik not edilir, sessizce elenerek geçiş sağlanmaz. Manifest dışı veya yinelenen kimlikler girdi hatasıdır. Bir denemeye birden çok sayı vermek yerine her tekrarı ayrı kimlikle kaydedin. Sağlayıcı başarısızlığında gözlenen boş hypothesis'i verin; gözlenemeyen süreyi boş bırakın.

Threshold JSON:

```json
{"hudMs":150,"firstInterimMs":1200,"releaseToFinalMs":2000,"werPercent":10}
```

Gerçek dosyalar hazırlanıp denetlendikten sonra, kullanıcı tarafından:

```sh
python3 tools/release_benchmark.py --manifest /private/tmp/release-manifest.json --speech /private/tmp/release-speech.jsonl --latency /private/tmp/release-latency.json --thresholds /private/tmp/release-thresholds.json --min-per-category 20 --attest-real-measurements > /private/tmp/release-report.json
```

`--attest-real-measurements` açık kullanıcı beyanıdır, aracın ölçümlerin gerçekliğini teknik olarak doğruladığı anlamına gelmez. Sentetik verilere bu bayrağı vermeyin. Bayrak yoksa sayılar raporlanır ama sonuç `not-ready` olur. CLI yalnızca stdout'a rapor basar; girdileri değiştirmez. Shell yönlendirmesinde rapor yolunu girdi dosyalarından farklı seçin.

## Read-only RecordLatency import ve mahremiyet

İncelenen kaynak: `Sources/VoiceTypingCore/RecordingStartCoordinator.swift`, `RecordingStartLatencyTrace.finish`. Desteklenen mevcut satır biçimi (değerler burada sentetiktir):

```text
[RecordLatency] provider=apple model=tr-TR keyEntry=0ms preparingPresented=20ms hudRunLoopYield=24ms recorderStarted=100ms firstInterim=650ms end=firstInterim
```

Timestamp/OSLog ön eki olabilir. `--record-latency-log /private/tmp/selected.log` manifestteki satır eşleştirmesiyle kullanılır. Araç yalnızca seçilen satırlardan `firstInterim`, `preparingPresented`, `hudRunLoopYield` alanlarını parse eder. İlk alan `firstInterimMs` için kullanılabilir; diğer ikisi yalnızca importer'ın döndürdüğü tanısal proxy değerleridir ve kabul raporunda HUD örneği sayılmaz. `AppDelegate` çağrı noktalarında `preparingPresented`, `showPreparing()` sonrasında işaretlenir. Gerçek HUD görünürlüğüne eşit olduğu varsayılmaz.

Mevcut log **releaseToFinal içermiyor**; başlangıçtan itibaren geçen süreler çıkarılarak bu metrik uydurulmaz. Eksik milestone, eşleşmeyen satır veya dosya sonrasındaki satır numarası ölçüm üretmez. Eksiklik JSON ile tamamlanmamışsa `not-ready` olur. Açık latency JSON alanı logdan önceliklidir; geçersiz açık alanın üzerine log değeri yazılmaz. `end=stop` veya başarısız başlangıç satırları otomatik başarılı örneğe dönüşmez. Tek denemenin print/OSLog kopyalarından yalnızca birini seçin; araç kendiliğinden oturum/cihaz/model eşleştirmesi yapmaz.

Log dosyası sadece okunur; hiçbir transkript aranmaz, çıkarılmaz veya rapora kopyalanmaz. Mümkünse kullanıcı sadece gerekli RecordLatency satırlarını özel bir dosyada sunsun. Rapor referans/hypothesis veya ham log içermez; kimlikler, cihaz adları, kategori ve sayısal özet içerir. Kimliklere kişisel bilgi koymayın. Yerel JSONL yine transkript taşır: erişim, saklama ve silme kullanıcı sorumluluğundadır. Uygulamanın diğer loglarının mahremiyeti bu aracın kapsamı dışındadır; burada uygulama loglaması değiştirilmez.

## Hesaplama ve kabul kararı

- NFC Unicode normalizasyonu; Türkçe `I → ı`, `İ → i`, ardından casefold; tüm Unicode noktalaması boşluk olur, whitespace üzerinden sözcüklere ayrılır. Aksanlar korunur. Kesme işaretleri sözcüğü böler; referans ve hypothesis aynı kurala tabidir.
- Levenshtein sözcük edit sayısı (ekleme/silme/değiştirme). Her cihaz × kategori için **toplam edit / toplam referans sözcüğü × 100** hesaplanır; cümle WER'lerinin ortalaması değildir, %100'ü aşabilir.
- Boş referansta WER tanımsızdır (`null`); hypothesis sözcükleri ayrıca `hallucinatedWords` olarak sayılır. Boş/boş sıfır hallucination'dır, eksik kanıt değildir.
- p50/p95 sıralanmış geçerli örneklerde `(n−1)×q` indeksinde doğrusal interpolasyonla hesaplanır. Boş örneklem `null`; tek örnekte iki yüzdelik aynı değerdir. Kararlar yuvarlanmamış değerlerle verilir. Cihazlar/kategoriler birleştirilerek problemli hücreler gizlenmez.
- `pass` / exit **0**: gerçek ölçüm beyanı, bütün eşikler, tüm planlı çiftler ve gerekli süreler, her cihaz/kategori minimumu tamam; bütün kapılar geçilmiş.
- `fail` / exit **1**: kanıt tam fakat eşik aşımı veya hallucination var.
- `not-ready` / exit **2**: eksik kapsam/metrik/eşik/beyan veya geçersiz girdi. Eksiklik ile başarısızlık birlikte varsa status `not-ready`, gözlenmiş başarısızlıklar ayrıca `failures` içinde korunur. Bu durum hiçbir zaman pass değildir.

Bu rapor nicel benchmark kapısıdır; bütün uygulama release onayının yerine geçmez. Gerçek oturumda ayrıca HUD'ın takılmaması, tuş bırakma/iptal, pause/quick_release final doğruluğu, hedef alana tek seferde yazma ve izin reddi gibi davranışlar insan tarafından kontrol edilmelidir. Bulguları oturum notuna ekleyin; araç gözlemlemediği davranışlar için başarı üretmez.

## CPU ve bellek ölçümü

`tools/performance_probe.py` yalnızca açıkça verilen PID'yi macOS `ps` ile okur. Mikrofonu açmaz, uygulama/medya başlatmaz, ağ kullanmaz. `python3 tools/performance_probe.py --help` parametreleri gösterir. Çalışan uygulamanın PID'sini `launchctl list com.antigravity.VoiceTyping` ile doğrulayın; sonra `--pid`, `--duration 30` ve `--interval 1` vererek ölçün. PID her kurulumda değişebilir; eski PID kullanmayın.

Boşta, aktif konuşma ve sonuç bekleme dönemlerini ayrı ölçün. Araç yaşam boyu `%cpu` yerine ardışık CPU zamanı farkı / monoton duvar saati farkından tek çekirdek yüzdesi hesaplar (100% = bir çekirdek; çok iş parçacığında aşılabilir). p50/p95 ve örneklenen en büyük RSS KiB raporlanır. Apple'ın ayrı servis süreçleri, GPU ve çocuk süreçler dahil değildir. `complete` yalnızca örneklemenin tamamlandığını söyler, yayın kabulü değildir. Süreç kapanır veya yürütülebilir dosya değişirse `incomplete` olur; aynı executable ile PID yeniden kullanımını her durumda saptayamaz.

Süre 1–120 saniye, aralık 0,2–5 saniye ile sınırlıdır. Her `ps` çağrısında zaman aşımı vardır. Karşılaştırmayı aynı cihazda, aynı cümleler/ayarlar ve benzer sistem yüküyle önce/sonra yapın. Makineye özgü veri olmadan CPU hedefi veya iyileşme yüzdesi iddia etmeyin. Özel ölçümleri Git tarafından dışlanan `release_measurements/` içinde veya repo dışında saklayın.

## Yayın öncesi davranış kontrolü

- 20 hızlı bas/bırak ve iptal/yeniden başlat: HUD hazırlıkta takılmamalı; eski sonuç yeni alana yazılmamalı.
- İzin reddi ve sonradan izin verme: açıklayıcı bildirim, mikrofonun boşta kapalı olması.
- Zed, Chrome metin alanı ve başka bir native editörde hedef alan/odak değişimi.
- Konuşmadan kapatma: hata veya uydurma metin olmamalı.
- Ağsız Apple kullanımı ve final bekleme zaman aşımı: kısmi metin erken kesinleşmemeli, kurtarma sınırlı olmalı.
- Uzun duraklama ve hızlı tuş bırakma: son sözcük korunmalı, metin tekrarlanmamalı.
- Hareketi Azalt açık/kapalı, dar ekran: HUD okunabilirliği ve canlı ölçer.
- Dağıtılacak paket için Developer ID imzası/notarization ve temiz kullanıcı kurulumu ayrıca doğrulanmalı; yerel codesign doğrulaması bunun yerine geçmez.

Bu adımlar manuel doğrulama gerektirir; otomatik testlerin geçmesi bunları yapılmış saymaz. Bu turda ölçüm olmadığı sürece yayın kararı **NOT READY (gerçek kabul verisi bekleniyor)** olarak kalır.

## Çalıştırılabilir sentetik smoke örneği

Aşağıdaki komutlar yalnızca geçici metin dosyaları üretir; donanım/ağ kullanmaz. **Gerçek benchmark değildir**, eksik kategori ve beyan nedeniyle beklenen exit kodu 2'dir:

```sh
mkdir -p /private/tmp/release-benchmark-synthetic
printf '%s\n' '{"devices":["dahili"],"cases":[{"id":"demo","device":"dahili","category":"normal"}]}' > /private/tmp/release-benchmark-synthetic/manifest.json
printf '%s\n' '{"id":"demo","reference":"IŞIK, İYİ!","hypothesis":"ışık iyi"}' > /private/tmp/release-benchmark-synthetic/speech.jsonl
printf '%s\n' '[{"id":"demo","hudMs":100,"firstInterimMs":600,"releaseToFinalMs":1100}]' > /private/tmp/release-benchmark-synthetic/latency.json
printf '%s\n' '{"hudMs":150,"firstInterimMs":1200,"releaseToFinalMs":2000,"werPercent":10}' > /private/tmp/release-benchmark-synthetic/thresholds.json
python3 tools/release_benchmark.py --manifest /private/tmp/release-benchmark-synthetic/manifest.json --speech /private/tmp/release-benchmark-synthetic/speech.jsonl --latency /private/tmp/release-benchmark-synthetic/latency.json --thresholds /private/tmp/release-benchmark-synthetic/thresholds.json
```

Offline deterministik testler (fixture değerleri sentetiktir; pass dalındaki beyan da yalnızca testtir):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/BenchmarkTests -p 'test_*.py' -v
```
