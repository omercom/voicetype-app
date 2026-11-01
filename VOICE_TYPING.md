# macOS Yerel Swift Sesle Yazma (Voice Typing) - Menü Çubuğu Uygulaması

macOS üzerinde herhangi bir metin alanındayken (tarayıcı, kod editörü, mesajlaşma uygulamaları vb.) **Sağ Command (Right Command)** tuşuna basılı tutarak konuşmanızı sağlayan ve bıraktığınız anda sesinizi ultra hızlı (Groq Whisper ile ~0.3 saniye) veya bağlamsal zekayla (Google Gemini) yazıya döküp aktif imlece yapıştıran, **tamamen yerel Swift (Zero Python)** menü çubuğu uygulaması.

---

## 🌟 Öne Çıkan Özellikler

1. **Sıfır Python Bağımlılığı (Zero Python Dependencies):**
   - Çalışma anında Python, pip, conda veya harici kütüphane gerektirmez.
   - Tek bir `swift build -c release` veya `./build.sh` komutu ile derlenen 360 KB boyutunda ultra hafif, bağımsız yerel macOS ikili dosyası (`VoiceTyping`).

2. **Yerel Menü Çubuğu Durum Simgesi (`NSStatusItem`):**
   - Menü çubuğunda canlı durum takibi: `🎙️` (Hazır), `🔴 Dinliyor...` (Kayıt), `⏳ Yazıyor...` (Deşifre).
   - Tek tıkla sağlayıcı (Apple Speech / Groq Whisper / Google Gemini / AssemblyAI Dictation) ve tetikleme modu değişimi.

3. **Yerel Ayarlar ve İzin Yönetimi Penceresi (Native Settings Dialog):**
   - **En Üstte macOS Sistem İzinleri:** Mikrofon ve Erişilebilirlik (Accessibility) izin durumları renkli durum rozetleri (`🟢` / `🔴` / `🟡`) ile gösterilir; "Sistem Ayarlarını Aç" butonlarıyla doğrudan ilgili macOS Gizlilik paneline tek tıkla erişilir.
   - **İzin kapsamı açıkça gösterilir:** Erişilebilirlik izni yalnızca global kısayolu algılama, odaklı yazı alanını bulma ve deşifreyi `Cmd+V` ile gönderme için kullanılır; ses/mikrofon izninden ayrıdır.
   - **Model ve Sağlayıcı Seçimi:** Groq Whisper (`whisper-large-v3`), Universal-3.5 Pro tabanlı AssemblyAI Dictation API ve yalnızca ses transkripsiyonuna yönelik Gemini (`gemini-3.5-transcribe-live`, `gemini-3.5-transcribe`) modelleri. Gemini model listesi API anahtarıyla webden yenilenebilir; genel Live/Flash/çeviri modelleri listelenmez.
   - **API Anahtarları:** Güvenli metin kutuları üzerinden Groq, Gemini ve AssemblyAI anahtarlarını yapılandırma.
   - **2 Saniyelik Canlı Test:** Ayarlar penceresinden anında ses kaydı alıp deşifreyi test etme imkanı (girdiğiniz güncel form değerleriyle anında test).

4. **Sağ Command Push-to-Talk Dinleyicisi (`CGEventTap`):**
   - **Basılı Tut (Push-to-Talk - Varsayılan):** Sağ Command tuşuna (Keycode 54) basılı tutarak konuşun, bıraktığınız anda deşifre edilip yapıştırılsın.
   - **Akıllı Hibrit (Smart Mode):** Hızlı bas-çek yapıldığında aç/kapa, basılı tutulduğunda bas-konuş.
   - **Aç/Kapa (Toggle):** Bir kez tıkla konuşmaya başla, tekrar tıkla bitir.
   - **Esc ile İptal:** Kayıt veya deşifre esnasında `Esc` tuşuna basıldığında işlem iptal edilir ve metin kutusuna yazılmaz.

5. **Yerel Ses Kaydı (`AVFoundation`):**
   - Donanım hızlandırmalı 16kHz 16-bit mono PCM ses kaydı.
   - Akıllı sessizlik tespiti ve kazara çok kısa basmaları filtreleme (`min_record_duration`).
   - Batch ses yollarında RMPN (Robust Modulation-Periodicity Normalization): sağlam gürültü tabanı, fonetik spektral flux ve Goertzel spektral entropisiyle tek statik netlik kazancı; canlı Apple/Gemini akışında mevcut realtime AGC korunur ve iki işlem üst üste uygulanmaz.

6. **Doğrudan `URLSession` Asenkron HTTP Deşifre:**
   - Groq Cloud API Whisper endpoint'ine multipart/form-data ile doğrudan bağlantı (~0.25 - 0.3s).
   - Google Gemini Transcribe Live WebSocket veya Transcribe REST API'ye optimize bağlantı.
   - AssemblyAI Dictation API (`/v1/transcribe/live`) ile varsayılan dolgu/öz-düzeltme temizliği ve `llm_response` → `text` güvenli fallback'i.

7. **Yerel Metin Enjeksiyonu ve Pano Yönetimi:**
   - Kayıt başındaki uygulama, pencere ve alan teslimattan önce doğrulanır. Genel ayarlarındaki **Hedef: İlk alana dön** seçeneği, odak değiştiğinde bu alanı yeniden odaklamayı dener.
   - **Hedef değişirse uyar** seçildiğinde odak değiştirilmez. İlk alan bulunamaz veya doğrulanamazsa metin panoda tutulur ve uyarı gösterilir.
   - Varsayılan yöntem, metni panoya koyup `Cmd+V` olayını yalnızca hedef sürece göndermektir.
   - `type_text_directly` açıksa desteklenen alanlarda seçili metin erişilebilirlik API'siyle değiştirilir. Alan bu işlemi desteklemiyorsa pano kullanılır.
   - `restore_clipboard` açıksa önceki pano yalnızca teslimat doğrulandığında ve pano başka bir işlem tarafından değiştirilmediyse geri yüklenir. Gönderimden önce iptal edilirse pano hâlâ uygulamaya aitse önceki içerik geri yüklenir.
   - Pano içeriğinin tamamı yedeklenemezse pano değiştirilmez ve aktarım durdurulur. Doğrulanamayan metin otomatik olarak yeniden gönderilmez.
   - Uzun metinlerde tam alan okunamıyorsa eklenen metin aralığı ayrıca kontrol edilir. Satır sonu biçimi farkları hatalı uyarıya neden olmaz; gerçekten doğrulanamayan aktarım bildirilir.
   - Geç gelen eski sağlayıcı sonuçları ve yinelenen çeviri sonuçları yeni kayda veya ikinci bir yapıştırmaya yol açmaz. Kurtarma klasörü ve kayıt dosyaları kullanıcıya özel izinlerle saklanır.

8. **İşitsel Geri Bildirim (`NSSound`):**
   - Apple sistem sesleri (`Tink`, `Pop`, `Glass`, `Basso`) ile ekrana bakmadan geri bildirim.

### Konuşmayı çevirerek yapıştırma

1. Ayarlar'da **Normal Dikte Tuşu** olarak **Sağ Command** seçin. Bu tuş, çeviri açık olsa bile çevirmeden dikte eder.
2. **Konuşma Dili** alanını `tr` yapın. **Sağ Option ile Çevir** seçeneğini açın ve hedef dil olarak **İngilizce [en]** seçin.
3. Geçerli bir Groq veya Gemini API anahtarı girin. Otomatik seçim önce Groq'u dener. Groq başarısızsa ve Gemini anahtarı varsa aynı metni Gemini'ye de gönderir. Bu, iki sağlayıcıda da ücret oluşturabilir. Özellikle Groq veya Gemini seçildiğinde diğer sağlayıcı denenmez.
4. Hedef yazı alanını seçin ve Sağ Option ile konuşun. Uygulama son çeviriyi hedef doğrulamasından sonra bir kez yapıştırır.

Normal dikte tuşu da Sağ Option olarak seçilirse, çeviri açıkken Sağ Option çevirili dikteye ayrılır. Normal dikte için farklı bir tuş seçin. Basılı tutma, akıllı mod ve aç/kapa modu iki kısayol için de geçerlidir. Diğer dikte kısayolu başlayan kaydı durdurmaz.

Çeviri açıksa metin Groq veya Gemini'ye gönderilir ve sağlayıcı ücret uygulayabilir. Apple Speech, Seda ve Gemini Live ara sonuçlarındaki kararlı cümleler konuşma sürerken de gönderilebilir. Bu cümleler son metne uymuyorsa yeniden çevrilir. Noktalama içermeyen ara sonuçlar ve canlı olmayan sağlayıcılar, kayıt sonunda çevrilir. Uzun metinler bölünür ve çevirileri sırayla birleştirilir. Bir parça başarısız olursa uygulama tüm orijinal metni kullanır ve kullanıcıyı uyarır. `Esc`, bekleyen istekleri iptal etmeyi dener; daha önce sağlayıcıya gönderilmiş metin geri alınamaz.

Seçili metni seslendirme kısayolu **⌥⌘S** olarak kalır; sistemdeki diğer seslendirme kısayolları değiştirilmez.

### Erişilebilirlik izni ne sağlar?

macOS Erişilebilirlik izni, VoiceTyping'in başka bir uygulama öndeyken arka planda çalışmasını sağlar. Uygulama bu izni:

- Seçilen global bas-konuş tuşunu ve `Esc` iptalini algılamak,
- Odaktaki uygulama ile düzenlenebilir yazı alanını bulup odağı korumak,
- Deşifre metnini panoya yazıp sentetik `Cmd+V` (ve isteğe bağlı Enter/Tab) göndermek

için kullanır. Hedefi ve aktarımı doğrulamak için odaktaki alanın erişilebilirlik özellikleri, okunabiliyorsa metni ve imleç konumu okunur. Normal klavye karakterleri kaydedilmez. macOS bu izni geniş bir sistem yetkisi olarak tanımlar; yalnızca güvendiğiniz uygulamalara verilmelidir. Mikrofon ve Apple Speech izinleri ayrı izinlerdir. İzin verilmezse global kısayol ve otomatik hedefe yazma kullanılamaz.

---

## 🚀 Derleme ve Başlatma

### Tek Komutla Derleme
```bash
./build.sh
# veya
swift build -c release && cp .build/release/VoiceTyping ./VoiceTyping
```

### Uygulamayı Başlatma
Arka planda (Menü Çubuğunda) başlatmak için:
```bash
./start.sh
```

Ön planda (konsol loglarıyla) çalıştırmak için:
```bash
./start.sh -f
# veya
./VoiceTyping
```

### Uygulamayı Durdurma
```bash
./stop.sh
```

---

## 🧪 Doğrulama ve Testler

Varsayılan testleri çalıştırmak için:
```bash
swift test
```
Testler; yapılandırma yönetimi, izinler, ses işleme, iptal, pano enjeksiyonu ve çeviri akışını doğrular. Varsayılan olarak canlı ses tanıma, canlı çeviri ve mikrofon testleri çalışmaz.

Canlı ses tanıma testleri için açıkça seçtiğiniz bir WAV örneği ve ilgili sağlayıcının API anahtarı gerekir. Dosya sağlayıcının sunucusuna gönderilir ve kullanım ücrete tabi olabilir. Test örneği Türkçe `merhaba` içermelidir.
```bash
VOICETYPE_TEST_LIVE_SPEECH=1 VOICETYPE_TEST_AUDIO_FILE=/ornek/ses.wav \
  swift test --filter 'VoiceTypingTests/testRealGroqTranscriptionWithSampleAudio'
```
Mikrofon testleri `VOICETYPE_TEST_MICROPHONE=1` ile, sabit metin kullanan canlı çeviri testleri `VOICETYPE_TEST_LIVE_TRANSLATION=1` ile ayrıca etkinleştirilir. Bu testleri yalnızca ilgili mikrofon ve API kullanımını kabul ettiğinizde çalıştırın.

---

## 📁 Swift Proje Mimarisi

- `Package.swift`: Swift Package Manager yapılandırması.
- `Sources/VoiceTyping/main.swift`: Uygulama giriş noktası (`NSApplication.shared`).
- `Sources/VoiceTypingCore/`:
  - `AppDelegate.swift`: Menü çubuğu (`NSStatusItem`), menü öğeleri, dikte geçmişi dışa aktarma ve yaşam döngüsü.
  - `Config.swift`: `config.json` okuma/yazma, model ve bağlam duyarlı istem çözümleme (`resolvedGeminiSystemPrompt`).
  - `TranscriptionProviderRegistry.swift`: Bildirimsel yetenekler (`TranscriptionCapabilities`), sağlayıcı tanımları ve merkezi eşleme.
  - `PromptTemplate.swift`: Güvenlik bütçeli (50 değişken, 8000 kr/değer, 32000 kr toplam) şablon yer tutucu motoru.
  - `PermissionManager.swift`: `AVCaptureDevice` mikrofon ve `AXIsProcessTrusted` erişilebilirlik denetimi ve sistem tercihleri bağlantıları.
  - `AudioRecorder.swift`: `AVFoundation` ile 16kHz mono WAV ses kaydı, ham sessizlik kontrolü ve sağlayıcıya göre tek geçişli ses hazırlığı.
  - `UtteranceClarityEnhancer.swift`: RMPN netlik raporu, bounded statik kazanç/soft limiter ve batch sağlayıcı işlem planı.
  - `Transcriber.swift`: Saf Swift `URLSession`/WebSocket ile Apple Speech, Groq, Gemini ve AssemblyAI istemcisi, paylaşımlı `CustomVocabularyParser`.
  - `AssemblyAIDictation.swift`: Dictation multipart protokolü, WAV doğrulama, `stt_prompt`/keyterms ve yanıt fallback'i.
  - `GeminiModelCatalog.swift`: Gemini API `models.list` yanıtını yalnızca ses transkripsiyon modelleri için filtreler.
  - `AppProfileFormatter.swift`: Hedef uygulamaya özel (Terminal, Code Editor, Messaging, Document) biçimlendirme kuralları.
  - `TextPolisher.swift`: Düşünme blokları, dolgu sözcükleri, sesli kısayollar, özel sözlük, dikte modu ve profil katmanlama zinciri.
  - `DictationHistoryManager.swift`: Uygulama etiketli dikte geçmişi saklama, panoya kopyalama ve Markdown dışa aktarma (`exportToMarkdown`, `exportToFile`).
  - `TextInjector.swift`: `NSPasteboard` ve `CGEvent` Cmd+V yapıştırma motoru.
  - `KeyListener.swift`: Düşük seviyeli `CGEventTap` ile Sağ Command (54) ve Esc (53) dinleyicisi.
  - `SoundManager.swift`: Apple `NSSound` sistem efektleri (`Tink`, `Pop`, `Glass`, `Basso`).
  - `SettingsWindow.swift`: Yerel macOS AppKit Ayarlar ve İzin Yönetimi grafik arayüzü.
- `Tests/VoiceTypingTests/`:
  - `VoiceTypingTests.swift`: Temel sistem, ses, pano, ayarlar ve enjeksiyon testleri.
  - `TranscriptionProviderRegistryTests.swift`: Sağlayıcı yetenekleri, API anahtarı eşlemeleri ve şablon entegrasyonu testleri.
  - `PromptTemplateTests.swift`: Değişken çıkarma, sanitizasyon limitleri ve determinizm testleri.
  - `DictationHistoryAndModeTests.swift`: Geçmiş Codable geriye dönük uyumluluğu, Markdown dışa aktarma ve dikte modu katmanlama testleri.
