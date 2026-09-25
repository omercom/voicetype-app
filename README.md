# VoiceType 🎙️ (macOS)

**macOS için hızlı, menü çubuğunda çalışan sesle yazma (dikte) uygulaması.**

Apple Speech, Google Gemini, Groq Whisper veya AssemblyAI Dictation API altyapısını kullanarak, erişilebilirlik desteği sunan metin alanlarında (Word, Notlar, Slack, Chrome, VS Code, WhatsApp vb.) konuşarak yazmanızı sağlar. Hedef uygulamanın kendi güvenlik ve erişilebilirlik kısıtları sonucu etkileyebilir.

---

## ✨ Öne Çıkan Özellikler

* **⚡ Düşük gecikmeli akış:** Google Gemini Transcribe Live ve Apple Speech desteklenen modellerde konuşma önizlemesini canlı gösterebilir; Groq Whisper ve Universal-3.5 Pro tabanlı AssemblyAI Dictation API kayıt sonunda deşifre eder.
* **🧠 RMPN ses netliği:** Groq, AssemblyAI ve Gemini REST kayıtlarında 20 ms karelerden sağlam gürültü tabanı, fonetik spektral flux, periyodiklik ve spektral entropi ölçülür. Tek statik kazanç + soft limiter ilk heceyi korur; canlı akışta double-AGC yapılmaz ve ham sessizlik gönderim eşiğini geçemez.
* **🇹🇷 Türkçe ve çoklu dil:** Dil seçimi (`tr`, `en`, `auto` ve sağlayıcının desteklediği diğer kodlar) ile çalışır; sonuç kalitesi seçilen motor ve dile bağlıdır.
* **💸 Sağlayıcı seçimi:** Apple Speech yerel çalışabilir; Gemini, Groq ve AssemblyAI için kendi API anahtarınız ve internet bağlantınız gerekir. Kota ve sağlayıcı kullanım şartları geçerlidir.
* **🎯 Hedefe yapıştırma:** Metni pano ve sentetik klavye olayıyla imlecin bulunduğu alana gönderir. Electron, Web ve Native uygulamalarda erişilebilirlik desteğine bağlı olarak çalışır.
* **⌨️ Bas-Konuş (Push-to-Talk) Kolaylığı:** Varsayılan **Sağ Command (⌘)** tuşuna basılı tutarak konuşun, bıraktığınız anda metniniz yazılsın.
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

### 2. Ücretsiz API Anahtarınızı Girin

1. Menü çubuğundaki **VoiceType** simgesine tıklayın ve **Ayarlar...** seçeneğini açın.
2. Kullanmak istediğiniz **Google Gemini**, **Groq** veya **AssemblyAI** API anahtarını yapıştırın.
3. Ayarlar anında otomatik kaydedilir.

*(Mikrofon ve Erişilebilirlik izinlerini Sistem Ayarları'ndan onaylayın. Apple Speech seçerseniz ayrıca Konuşma Tanıma izni gerekir.)*

---

## 💡 Nasıl Kullanılır?

1. İmlecinizi yazmak istediğiniz yere konumlandırın (örneğin bir mesaj kutusu, arama çubuğu veya belge).
2. Klavyenizdeki **Sağ Command (⌘)** tuşuna basılı tutun ve konuşun.
3. Konuşmanız bittiğinde tuşu bırakın; metniniz imlecin olduğu yere anında yapıştırılır.

---

## 🔐 Gizlilik ve izinler

* API anahtarları kullanıcı hesabındaki `~/.voice_typing/config.json` dosyasında saklanır; kurulum sırasında uygulama paketine kopyalanmaz.
* Mikrofon izni ses kaydı içindir. Apple Speech seçiliyse Konuşma Tanıma izni de gerekir; Gemini, Groq ve AssemblyAI seçildiğinde bu izin kullanılmaz.
* **Gemini, Groq veya AssemblyAI seçildiğinde ses, seçtiğiniz sağlayıcının API'sine gönderilir. Apple Speech seçildiğinde Apple'ın macOS konuşma tanıma davranışı geçerlidir. AssemblyAI istekleri ayrıca doğal Türkçe macOS diktasyonu bağlamını `stt_prompt` ile belirtir; özel terimler `keyterms_prompt` ile sınırlı tutulur.

### Erişilebilirlik izni neden gerekli?

Bu izin, VoiceTyping'in başka bir uygulama öndeyken menü çubuğunda arka planda çalışabilmesi için gereklidir. VoiceTyping bu izni şu işler için kullanır:

1. Seçtiğiniz global bas-konuş tuşunu ve `Esc` iptalini algılamak. Uygulama normal klavye karakterlerini kaydetmez.
2. Kayıt başladığında öndeki uygulamayı ve odaktaki düzenlenebilir yazı alanını bulmak; deşifre bitince odağı aynı yere geri getirmek.
3. Metni panoya yazıp sentetik `Cmd+V` ile hedef uygulamaya, isteğe bağlı otomatik gönderim tuşuyla iletmek. Pano davranışı `Gelişmiş > Pano` ayarına bağlıdır.

macOS bu yetkiyi geniş kapsamlı bir sistem izni olarak gösterir. VoiceTyping'in bu akışında ekran içeriği, dosyalar veya normal klavye metni okunmaz; yine de bu izni yalnızca güvendiğiniz uygulamalara vermelisiniz. İzin verilmezse global kısayol ve otomatik hedefe yazma çalışmaz.

## 🛠️ Sistem Gereksinimleri

* macOS 13.0+ (Ventura, Sonoma, Sequoia)
* Apple Silicon (M1/M2/M3/M4) veya Intel Mac

---

## 📄 Lisans

MIT License. Tamamen açık kaynak ve ücretsizdir.
