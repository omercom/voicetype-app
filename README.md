# VoiceType 🎙️ (macOS)

**macOS için hızlı, menü çubuğunda çalışan sesle yazma (dikte) uygulaması.**

Apple Speech, Seda-v0.1, Google Gemini, Groq Whisper veya AssemblyAI Dictation API kullanarak erişilebilir metin alanlarına konuşarak yazmanızı sağlar. Hedef uygulamanın güvenlik ve erişilebilirlik kısıtları sonucu etkileyebilir.

---

## ✨ Öne Çıkan Özellikler

* **⚡ Düşük gecikmeli akış:** Google Gemini Transcribe Live ve Apple Speech desteklenen modellerde konuşma önizlemesini canlı gösterebilir; Groq Whisper ve Universal-3.5 Pro tabanlı AssemblyAI Dictation API kayıt sonunda deşifre eder.
* **🧠 RMPN ses netliği:** Groq, AssemblyAI ve Gemini REST kayıtlarında 20 ms karelerden sağlam gürültü tabanı, fonetik spektral flux, periyodiklik ve spektral entropi ölçülür. Tek statik kazanç + soft limiter ilk heceyi korur; canlı akışta double-AGC yapılmaz ve ham sessizlik gönderim eşiğini geçemez.
* **🇹🇷 Türkçe ve çoklu dil:** Dil seçimi (`tr`, `en`, `auto` ve sağlayıcının desteklediği diğer kodlar) ile çalışır; sonuç kalitesi seçilen motor ve dile bağlıdır.
* **💸 Sağlayıcı seçimi:** Apple Speech yerel çalışabilir; Gemini, Groq ve AssemblyAI için kendi API anahtarınız ve internet bağlantınız gerekir. Kota ve sağlayıcı kullanım şartları geçerlidir.
* **🎯 Hedefe yapıştırma:** Metni pano ve sentetik klavye olayıyla imlecin bulunduğu alana gönderir. Electron, Web ve Native uygulamalarda erişilebilirlik desteğine bağlı olarak çalışır.
* **⌨️ Bas-Konuş (Push-to-Talk) Kolaylığı:** Varsayılan **Sağ Command (⌘)** tuşuna basılı tutarak konuşun, bıraktığınız anda metniniz yazılsın.
* **🌐 Çevirili dikte:** İsteğe bağlı **Sağ Option** kısayoluyla konuşmayı İngilizce, Almanca, İspanyolca veya Fransızcaya çevirerek yazın.
* **🔇 Arka plan sesini yönetme:** Tercihe göre sesi kısabilir veya dikte sırasında gerçekten çalan medyayı duraklatıp bitince devam ettirebilir.
* **💎 Minimal Dinamik Ada Tasarımı:** Kompakt 24 pt mikrofon rozeti, kesintiye dayanıklı genişlik ve saydamlık geçişleri. macOS **Erişilebilirlik > Ekran > Hareketi azalt** açıkken geçişler anlık, dekoratif animasyonlar kapalıdır (2.1, build 12).
* **⚙️ Modern macOS Standartları:** Her yaptığınız ayar anında otomatik olarak kaydedilir; karmaşık menüler veya kaydet butonları yoktur.
* **🏝️ MacBook Çentiği (Dynamic Island) modu:** Ayarlar → Gelişmiş → *Gösterge Stili*'nden seçilir. Ada doğrudan kameranın bulunduğu çentiğe yapışır; köşeleri ovaldir ve tam opak siyah yüzey kullanır. Metin kameranın altında ortalanır, canlı ekolayzır sağ kanatta kamera hizasında durur. Metin uzadıkça yazı orantılı olarak küçülür (okunabilirlik sınırına kadar), ada da metne göre genişler. Çentiksiz ekranlarda seçenek otomatik olarak pasifleşir.
* **🎚️ Çift eşikli konuşma kapısı (hysteresis VAD):** Konuşmayı *başlatan* eşik ile *sürdüren* eşik ayrıdır (sürdürme eşiği ~6 dB daha aşağıda). Bu sayede kısık sesle başlayan konuşma "ses algılanmadı" uyarısına takılmaz ve cümle ortasındaki doğal duraklamalar cümleyi ikiye bölmez. Ortam gürültüsü her kaydın başında kalibre edilir, böylece gürültülü odada ortam sesi kendiliğinden konuşma sayılmaz.
* **🛡️ Kontrolsüz tekrar koruması:** Whisper ailesi modelleri sessizlik veya arka plan gürültüsünde aynı ifadeyi onlarca kez üretebilir. Bu tekrarlar metin üzerinde otomatik olarak temizlenir; gerçek konuşmadaki ikili/üçlü vurgular korunur.

> [!NOTE]
> **Yapılandırma:** Gösterge stili varsayılan olarak mevcut alt-ortada kapsüldür ve Ayarlar'dan değiştirilebilir. **Ada yazı boyutu ayarı yoktur** — boyut tamamen otomatik hesaplanır (sabit ada genişliği + satır sarma + okunabilirlik tabanı). `decode_tokens_per_sec: 0` tekrar korumasını tamamen kapatır. Mevcut config dosyalarınız (artık kullanılmayan `hud_font_size` anahtarı dahil) sorunsuz çalışmaya devam eder.

### Bu sürümdeki teknik uyarlamalar

Aşağıdaki yetenekler [AlwaysWhisper](https://github.com/kzkhykw/AlwaysWhisper) projesinin mühendislik yaklaşımından **uyarlanmıştır** (kod kopyalanmamış; algoritma, ölçü ve sabitler kendi Swift mimarimize yeniden yazılmıştır):

| Yetenek | Kaynak yaklaşım | Bu projedeki karşılığı |
|---|---|---|
| Çentik geometrisi | `safeAreaInsets` + `auxiliaryTopLeft/RightArea` ile kamera ölçümü | [`NotchGeometry.swift`](Sources/VoiceTypingCore/NotchGeometry.swift) |
| Ada yüzeyi | Tam opak siyah (`background_alpha = 1.0`), üst köşeler kare, alt köşeler yuvarlak | `updateNotchPosition` |
| VU metre | 20×20pt kutu, 5 simetrik çubuk (ağırlık `.45/.75/1.0/.75/.45`), genişlik = kutu/10, merkezden büyüme, yeşil/gri | [`NotchAudioMeter.swift`](Sources/VoiceTypingCore/NotchAudioMeter.swift) |
| Seviye yumuşatma | Zaman-tabanlı EMA (tau: çıkış `.035` / iniş `.18`), 30 FPS | `NotchAudioMeter.smooth` |
| Konuşma kapısı | `GATE_DEFAULT`, `STAY_GATE_RATIO = 0.5`, `SILENCE_SEC = 0.4`, `MAX_SEC = 8` | [`SpeechGate.swift`](Sources/VoiceTypingCore/SpeechGate.swift) |
| Deşifre bütçesi | `decode_sample_len = 16 * sn + 32` | [`DecodeBudget.swift`](Sources/VoiceTypingCore/DecodeBudget.swift) |

> [!IMPORTANT]
> **Sağlayıcı gerçekleri canlı API testiyle doğrulandı.** Groq `/audio/transcriptions` `max_tokens` parametresini **reddeder** (HTTP 400 `unknown_param`); Gemini ise iç "düşünme" token'larını `maxOutputTokens` bütçesinden düşer. Bu yüzden ses süresine bağlı tavan yalnızca güvenli olan yolda uygulanır; Groq tarafında koruma [`RepetitionGuard.swift`](Sources/VoiceTypingCore/RepetitionGuard.swift) ile yanıt metni üzerinde sağlanır.

---

## 🚀 Hızlı Başlangıç (Kurulum)

### 1. Derleme ve Çalıştırma

Terminal'i açın ve şu komutları çalıştırın:

```bash
# Projeyi derleyin
./build.sh

# Uygulamayı Uygulamalar klasörüne kurup başlatın
./install.sh
```

`install.sh` yeniden release derlemesi yapar; release kaynak paketini kullanır, imzayı doğrular ve `/Applications/VoiceTyping.app` yolunu LaunchAgent üzerinden başlatır. Standart kurulum imzalı executable dosyasını değiştirmeden kopyalar; build ve kurulum hash'leri birebir eşleşir.

### 2. Gerekirse API Anahtarınızı Girin

1. Menü çubuğundaki **VoiceType** simgesine tıklayın ve **Ayarlar...** seçeneğini açın.
2. Kullanmak istediğiniz **Google Gemini**, **Groq** veya **AssemblyAI** API anahtarını yapıştırın.
3. Ayarlar anında otomatik kaydedilir.

*(Mikrofon ve Erişilebilirlik izinlerini Sistem Ayarları'ndan onaylayın. Apple Speech seçerseniz ayrıca Konuşma Tanıma izni gerekir.)*

---

## 💡 Nasıl Kullanılır?

1. İmlecinizi yazmak istediğiniz yere konumlandırın (örneğin bir mesaj kutusu, arama çubuğu veya belge).
2. Klavyenizdeki **Sağ Command (⌘)** tuşuna basılı tutun ve konuşun.
3. Konuşmanız bittiğinde tuşu bırakın; metniniz imlecin olduğu yere yapıştırılır.

### Çevirerek dikte et

1. Ayarlar'da **Sağ Option ile Çevir** seçeneğini açın ve hedef dili seçin.
2. Groq veya Gemini API anahtarınızı ayarlayın.
3. Bir metin alanı seçin. **Sağ Option** tuşuna basılı tutup konuşun ve bitince tuşu bırakın.
4. Normal dikte için **Sağ Command** tuşunu kullanın.

Canlı tanıma ara sonuç verdiğinde uygulama tamamlanan cümleleri konuşma sırasında çevirmeyi deneyebilir. Sonuç bir kez yapıştırılır. Çeviri başarısızsa özgün metin korunur. Metin, seçilen çeviri sağlayıcısına gönderilir; otomatik seçimde Groq başarısız olursa yapılandırılmış Gemini'ye de gönderilebilir. Kullanım ücrete tabi olabilir. Ayrıntılar için [dikte ve çeviri kılavuzuna](VOICE_TYPING.md) bakın.

### Türkçe metni seslendir — Antalia Mini

1. Metni seçin ve **⌥⌘S (Option + Command + S)** tuşlarına basın.
2. Okumayı **⌥⌘S**, **Esc** veya menüdeki **Metni Seslendir → Okumayı Durdur** ile durdurun.
3. Sağ tık menüsünde **Servisler → VoiceType ile Seslendir** seçeneğini kullanabilirsiniz.
4. Seçim alınamıyorsa metni kopyalayıp **Metni Seslendir → Panoyu Seslendir** seçeneğini kullanın.

Servisler yalnızca bu macOS özelliğini destekleyen uygulamalarda görünür.
Gerekirse Sistem Ayarları → Klavye → Klavye Kestirmeleri → Servisler bölümünde servisi etkinleştirin.
Seçili metin için Erişilebilirlik izni gerekir; servis veya açık pano komutu bu izni gerektirmez.
Kısayol çakışırsa menü bunu gösterir. Tuşun fiziksel konumu ANSI S konumudur.
Okuma dikte sırasında başlamaz; yeni dikte mevcut okumayı durdurur.

Motor kurulumu için `uv` ve ilk indirmede internet gerekir:

```bash
VOICETYPE_SETUP_TTS=1 ./install.sh
# Mevcut kurulum için yalnızca motoru kur:
./setup-tts.sh
```

Motor Python 3.12 ortamında `~/.voice_typing/tts/.venv` altında kurulur.
Uygulama modeli ayrı, kalıcı bir süreçte ısıtır; hazır olunca MPS veya CPU bilgisini menüde gösterir.
Apple Silicon'da MPS, başlangıçta desteklenmezse CPU kullanılır. Çalışma sırasında ağ erişimi kapalıdır.
Türkçe tek ses kullanılır; ses klonlama yoktur. Bir istekte en fazla 30.000 Unicode karakter kabul edilir.
Uygulama metni yaklaşık 350 karakterlik bölümlere ayırır ve her bölümün sesini sırayla üretip çalar.
Bütün metnin üretilmesini beklemez. Bölümler arasında kısa hazırlama aralıkları olabilir; canlı ses akışı değildir.
[Antalia Mini demosu ve hız ölçümleri](experiments/antalia-mini-demo/README.md) ayrıca kullanılabilir.
EMA kullanan eski kurulumlarda `./setup-tts.sh` ve `./install.sh` komutlarını yeniden çalıştırın.

### Chrome'da seçili metnin yanında Oku butonu

```sh
./setup-chrome.sh
```

Chrome → `chrome://extensions` → **Geliştirici modu** → **Paketlenmemiş öğe yükle** bölümünden
bu projenin `browser-extension/chrome` klasörünü seçin. Açık sayfaları yenileyin.
Web sayfasında metin seçip **🔊 Oku** butonuna basın.
**⏸ Duraklat** okumaya ara verir; **▶ Devam et** aynı ses konumundan devam eder.
Ayrı **■ Durdur** butonu okumayı tamamen iptal eder.
Buton istek, hazırlık, okuma ve bitiş durumlarını gösterir; karakter sayısı, geçen süre ve bölüm ilerlemesi görünür.
Duraklatırken süre ve bölüm ilerlemesi sabit kalır.
Sınırı aşan metin ve bağlantı hataları aynı seçimde görünür kalır.
Eklenti aynı yerel Antalia Mini motorunu kullanır; ayrı model veya bulut API'si gerekmez.
Parola, kart ve özel işaretlenmiş alanlar dışlanır. Chrome iç sayfaları ve iframe desteklenmez.
[Chrome kurulumu, gizlilik ve sorun giderme](browser-extension/README.md).

## 🇹🇷 Harfiyen · Seda-v0.1 ile yerel Türkçe dikte

[Harfiyen](https://github.com/ozcancelik/harfiyen) bir STT projesidir; metni seslendirmez.
Bu uygulama Harfiyen'in kullandığı [Seda-v0.1](https://huggingface.co/atasoglu/seda-v0.1) modelini ayrı bir dikte sağlayıcısı olarak sunar.
Mevcut TTS motoru değişmez.

```bash
# uv ve Python 3.12 gerekir; uv Python'u gerekirse indirir.
./setup-stt.sh
# Uygulama paketini güncellemek için:
./install.sh
# Alternatif: VOICETYPE_SETUP_STT=1 ./install.sh
```

Menü çubuğu → **Ses Tanıma → Harfiyen · Seda-v0.1** seçin.
Ayarlar'daki sağlayıcı seçimi de Seda-v0.1'i içerir. Dil `tr` olmalıdır.
API anahtarı ve Apple Konuşma Tanıma izni gerekmez; mikrofon ve erişilebilirlik izinleri gerekir.

- İlk kurulum model dosyalarını indirir. Dikte sırasında model ve dil modeli tamamen yerel CPU üzerinde çalışır.
- Konuşurken HUD'da canlı ara metin görünür. Hedef uygulamaya yalnızca kayıt sonundaki nihai metin yazılır.
- Kalıcı işçi modeli ardışık dikteler arasında bellekte tutar. İlk açılışta model yüklenirken ses sırayla tamponlanır.
- Model yaklaşık 0,64 saniyelik bağlam bloklarıyla çalışır; her ses paketinde yeni kelime üretmesi beklenmez.
- Canlı bağlantı hatasında aynı model kaydedilen WAV ile yeniden denenir; buluta geçilmez.
- Model küçük harfli, noktalamasız metin üretir ve sayıları sözcük olarak yazar. Uygulamanın mevcut metin düzenlemesi sonrasında uygulanır.
- Özel sözlük, sistem istemi ve otomatik dil algılama desteklenmez. En fazla 10 dakikalık 16 kHz mono PCM16 WAV kabul edilir.
- Model yükleme ve kayıt sonrası sonuç için ayrı 90 saniyelik zaman aşımı vardır. Canlı kayıt en fazla 10 dakika sürer.
- WAV kurtarmasının özel geçici dosyası bitişte veya iptalde silinir.
- Mevcut dikte kurtarma ve geçmiş ayarları geçerlidir; bu entegrasyon bu kayıtları devre dışı bırakmaz.
- Çalışma ortamı `~/.voice_typing/stt/seda` altında tutulur. Model sürümü ve Python bağımlılıkları sabitlenmiştir.
- Akustik model Apache-2.0 lisanslıdır. Kullanılan RNNLM ve 2-gram dil modelleri CC BY-SA 4.0 lisanslıdır; ayrıntılar model kartındadır.
- Apple M5 üzerinde aynı örnekte CPU (2 iş parçacığı) 0,29 saniye, Core ML 0,55–0,63 saniye sürdü. Bu nedenle CPU kullanılır.
- MPS bu ONNX motorunda doğrudan desteklenmez. Core ML seçeneği GPU/Neural Engine üzerinde tam çalışma garantisi değildir.
- [Seda çalışma ortamı ve ölçüm notları](runtime/seda/README.md).

---

## 🔐 Gizlilik ve izinler

* API anahtarları kullanıcı hesabındaki `~/.voice_typing/config.json` dosyasında saklanır; kurulum sırasında uygulama paketine kopyalanmaz.
* Mikrofon izni ses kaydı içindir. Apple Speech seçiliyse Konuşma Tanıma izni de gerekir; Seda-v0.1, Gemini, Groq ve AssemblyAI bu izni kullanmaz.
* **Gemini, Groq veya AssemblyAI seçildiğinde ses, seçtiğiniz sağlayıcının API'sine gönderilir. Apple Speech seçildiğinde Apple'ın macOS konuşma tanıma davranışı geçerlidir. AssemblyAI istekleri ayrıca doğal Türkçe macOS diktasyonu bağlamını `stt_prompt` ile belirtir; özel terimler `keyterms_prompt` ile sınırlı tutulur.

### Erişilebilirlik izni neden gerekli?

Bu izin, VoiceTyping'in başka bir uygulama öndeyken menü çubuğunda arka planda çalışabilmesi için gereklidir. VoiceTyping bu izni şu işler için kullanır:

1. Seçtiğiniz global bas-konuş tuşunu ve `Esc` iptalini algılamak. Uygulama normal klavye karakterlerini kaydetmez.
2. Kayıt başladığında öndeki uygulamayı ve odaktaki düzenlenebilir yazı alanını bulmak; deşifre bitince odağı aynı yere geri getirmek.
3. Metni panoya yazıp sentetik `Cmd+V` ile hedef uygulamaya, isteğe bağlı otomatik gönderim tuşuyla iletmek. Pano davranışı `Gelişmiş > Pano` ayarına bağlıdır.
4. Yalnızca seslendirme komutu verdiğinizde seçili metni okumak. Seçim alınamazsa sentetik `Cmd+C` denenir; eski pano korunur.

macOS bu yetkiyi geniş kapsamlı bir sistem izni olarak gösterir. Uygulama ekran görüntüsü almaz veya normal klavye karakterlerini kaydetmez.
Seslendirme açık kullanıcı komutuyla seçili metni, servis metnini veya panoyu okur; eski panodaki metni otomatik kullanmaz.
Güvenli alanlar ve güvenli klavye girişi seçili metin akışında engellenir. Açık pano komutunda içeriği kullanıcı kontrol eder.
Metin ve geçici ses yerelde işlenir; uygulama metni günlüğe yazmaz. Ses bitince, iptalde veya normal kapanışta geçici dosya silinir.
Zorla kapanma veya elektrik kesintisi geçici dosyayı bırakabilir. Bu dosyalar kullanıcıya özel geçici klasörde tutulur.
İzin verilmezse seçili metin alma, bas-konuş ve otomatik hedefe yazma çalışmaz; yalnızca güvendiğiniz uygulamalara izin verin.

## 🛠️ Sistem Gereksinimleri

* macOS 13.0+ (Ventura, Sonoma, Sequoia)
* Apple Silicon (M1/M2/M3/M4) veya Intel Mac

---

## 📄 Lisans

MIT License. Tamamen açık kaynak ve ücretsizdir.
