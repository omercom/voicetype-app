# macOS Yerel Swift Sesle Yazma (Voice Typing) - Menü Çubuğu Uygulaması

macOS üzerinde herhangi bir metin alanındayken (tarayıcı, kod editörü, mesajlaşma uygulamaları vb.) **Sağ Command (Right Command)** tuşuna basılı tutarak konuşmanızı sağlayan ve bıraktığınız anda sesinizi ultra hızlı (Groq Whisper ile ~0.3 saniye) veya bağlamsal zekayla (Google Gemini) yazıya döküp aktif imlece yapıştıran, **tamamen yerel Swift (Zero Python)** menü çubuğu uygulaması.

---

## 🌟 Öne Çıkan Özellikler

1. **Sıfır Python Bağımlılığı (Zero Python Dependencies):**
   - Çalışma anında Python, pip, conda veya harici kütüphane gerektirmez.
   - Tek bir `swift build -c release` veya `./build.sh` komutu ile derlenen 360 KB boyutunda ultra hafif, bağımsız yerel macOS ikili dosyası (`VoiceTyping`).

2. **Yerel Menü Çubuğu Durum Simgesi (`NSStatusItem`):**
   - Menü çubuğunda canlı durum takibi: `🎙️` (Hazır), `🔴 Dinliyor...` (Kayıt), `⏳ Yazıyor...` (Deşifre).
   - Tek tıkla sağlayıcı (Groq Whisper / Google Gemini) ve tetikleme modu değişimi.

3. **Yerel Ayarlar ve İzin Yönetimi Penceresi (Native Settings Dialog):**
   - **En Üstte macOS Sistem İzinleri:** Mikrofon ve Erişilebilirlik (Accessibility) izin durumları renkli durum rozetleri (`🟢` / `🔴` / `🟡`) ile gösterilir; "Sistem Ayarlarını Aç" butonlarıyla doğrudan ilgili macOS Gizlilik paneline tek tıkla erişilir.
   - **Model ve Sağlayıcı Seçimi:** Groq Whisper (`whisper-large-v3`) ve Gemini (`gemini-3.5-flash`, `gemini-3.6-flash`, `gemini-3.5-flash-lite`) modelleri.
   - **API Anahtarları:** Güvenli metin kutuları üzerinden Groq ve Gemini anahtarlarını yapılandırma.
   - **2 Saniyelik Canlı Test:** Ayarlar penceresinden anında ses kaydı alıp deşifreyi test etme imkanı (girdiğiniz güncel form değerleriyle anında test).

4. **Sağ Command Push-to-Talk Dinleyicisi (`CGEventTap`):**
   - **Basılı Tut (Push-to-Talk - Varsayılan):** Sağ Command tuşuna (Keycode 54) basılı tutarak konuşun, bıraktığınız anda deşifre edilip yapıştırılsın.
   - **Akıllı Hibrit (Smart Mode):** Hızlı bas-çek yapıldığında aç/kapa, basılı tutulduğunda bas-konuş.
   - **Aç/Kapa (Toggle):** Bir kez tıkla konuşmaya başla, tekrar tıkla bitir.
   - **Esc ile İptal:** Kayıt veya deşifre esnasında `Esc` tuşuna basıldığında işlem iptal edilir ve metin kutusuna yazılmaz.

5. **Yerel Ses Kaydı (`AVFoundation`):**
   - Donanım hızlandırmalı 16kHz 16-bit mono PCM ses kaydı.
   - Akıllı sessizlik tespiti ve kazara çok kısa basmaları filtreleme (`min_record_duration`).

6. **Doğrudan `URLSession` Asenkron HTTP Deşifre:**
   - Groq Cloud API Whisper endpoint'ine multipart/form-data ile doğrudan bağlantı (~0.25 - 0.3s).
   - Google Gemini REST API'ye optimize JSON yüküyle doğrudan bağlantı.

7. **Yerel Metin Enjeksiyonu ve Pano Yönetimi:**
   - `NSPasteboard` ve `CGEvent` Cmd+V simülasyonu ile sıfır gecikmeli yapıştırma.
   - İsteğe bağlı olarak yapıştırma sonrası eski panoyu otomatik geri yükleme (`restore_clipboard`).

8. **İşitsel Geri Bildirim (`NSSound`):**
   - Apple sistem sesleri (`Tink`, `Pop`, `Glass`, `Basso`) ile ekrana bakmadan geri bildirim.

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

Tüm birim ve entegrasyon testlerini çalıştırmak için:
```bash
swift test
```
Testler; yapılandırma yönetimi, LaTeX yasağı kontrolleri, izin denetleyicisi, ses kaydı, iptal mekanizması, pano enjeksiyonu ve `live_recording.wav` ile canlı Groq deşifresini uçtan uca doğrular.

---

## 📁 Swift Proje Mimarisi

- `Package.swift`: Swift Package Manager yapılandırması.
- `Sources/VoiceTyping/main.swift`: Uygulama giriş noktası (`NSApplication.shared`).
- `Sources/VoiceTypingCore/`:
  - `AppDelegate.swift`: Menü çubuğu (`NSStatusItem`), menü öğeleri ve yaşam döngüsü.
  - `Config.swift`: `config.json` okuma, yazma ve model fiyat/özellik tanımları.
  - `PermissionManager.swift`: `AVCaptureDevice` mikrofon ve `AXIsProcessTrusted` erişilebilirlik denetimi ve sistem tercihleri bağlantıları.
  - `AudioRecorder.swift`: `AVFoundation` ile 16kHz mono WAV ses kaydı ve sessizlik kontrolü.
  - `Transcriber.swift`: Saf Swift `URLSession` ile Groq ve Gemini REST API istemcisi.
  - `TextInjector.swift`: `NSPasteboard` ve `CGEvent` Cmd+V yapıştırma motoru.
  - `KeyListener.swift`: Düşük seviyeli `CGEventTap` ile Sağ Command (54) ve Esc (53) dinleyicisi.
  - `SoundManager.swift`: Apple `NSSound` sistem efektleri (`Tink`, `Pop`, `Glass`, `Basso`).
  - `SettingsWindow.swift`: Yerel macOS AppKit Ayarlar ve İzin Yönetimi grafik arayüzü.
- `Tests/VoiceTypingTests/VoiceTypingTests.swift`: Kapsamlı XCTest test paketi.
