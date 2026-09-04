# macOS Sesle Yazma (Voice Typing) - Menü Çubuğu Uygulaması

macOS üzerinde herhangi bir metin alanındayken (tarayıcı, kod editörü, mesajlaşma uygulamaları vb.) **Sağ Command** tuşuna basılı tutarak konuşmanızı sağlayan ve bıraktığınız anda sesinizi ultra hızlı (Groq Whisper ile ~0.3 saniye) veya bağlamsal zekayla (Google Gemini 3.6 Flash) yazıya döküp aktif imlece yapıştıran hafif (lightweight) menü çubuğu uygulaması.

---

## Özellikler

1. **Sağ Command (Right Command - Keycode 54) Tetikleyici:**
   - **Basılı Tut Modu (Hold / Push-to-Talk - Varsayılan):** Tuşa basılı tutulduğu sürece mikrofon kaydeder, bırakıldığı anda konuşma deşifre edilip aktif metin kutusuna yazılır.
   - **Akıllı Mod (Smart Mode):** Tuşa basılı tutup konuştuğunuzda bas-konuş; hızlı bas-bırak yapıldığında aç-kapa eller serbest moduna geçer.
   - **Aç/Kapa Modu (Toggle):** Bir kez basıldığında kayda başlar, tekrar basıldığında yapıştırır.
   - **Esc ile Tam İptal:** İster ses kaydı sırasında, ister deşifre aşamasında olsun `Esc` tuşuna basıldığında işlem anında durdurulur ve metin kutusuna hiçbir şey yazılmaz.

2. **Ultra Hızlı ve Sıfır Disk Gecikmesi (Zero-Latency In-Memory):**
   - Ses kaydı diske yazılmaz; tamamen RAM içinde 16kHz mono WAV tamponunda tutulur.
   - Groq Cloud API ile Whisper Large v3 Turbo modeliyle ~0.3 saniyede deşifre tamamlanır.

3. **Çoklu Sağlayıcı ve Model Desteği (Best Prices):**
   - **Groq Whisper Large v3 Turbo:** ~0.3s işlem süresi, 0.00018 USD / dakika (Günlük 8 saat ücretsiz kota).
   - **Groq Whisper Large v3:** En yüksek Türkçe doğruluk, 0.00018 USD / dakika.
   - **Google Gemini 3.6 Flash:** Doğal dil, otomatik noktalama ve bağlam tamamlama (Ücretsiz / çok düşük maliyet).
   - **Google Gemini 3.5 Flash:** Hızlı ve dengeli multimodal model.

4. **Kusursuz Metin Enjeksiyonu ve Pano Koruması:**
   - macOS `NSPasteboard` ve native `Quartz` olay simülasyonu ile aktif textbox'a `Cmd+V` gönderir.
   - İsteğe bağlı olarak yapıştırma sonrası kullanıcının eski panosunu otomatik geri yükler (`restore_clipboard`).

5. **İşitsel ve Görsel Geri Bildirim:**
   - Apple sistem sesleri (`Tink`, `Pop`, `Glass`, `Basso`) ile ekrana bakmadan durum takibi.
   - Menü çubuğu simgesi: `🎙️` (Hazır), `🔴` (Kaydediyor), `⚡` (Deşifre Ediliyor).

6. **Kolay Ayar Yönetimi (Menü Çubuğu):**
   - Sağlayıcı ve model seçimi tek tıkla yapılır.
   - Groq ve Gemini API anahtarları menüdeki yerel Cocoa iletişim kutularından girilebilir veya güncellenebilir.

---

## Kurulum ve Başlatma

### 1. API Anahtarlarını Tanımlama
`.env` dosyanıza veya menü çubuğundan ilgili ayar penceresine anahtarlarınızı girin:
```env
GROQ_API_KEY=gsk_...
GEMINI_API_KEY=AIza...
```

### 2. Uygulamayı Başlatma

Arka planda (Daemon / Menü Çubuğu) çalıştırmak için:
```bash
./start.sh
```

Ön planda (konsol loglarıyla) çalıştırmak için:
```bash
./start.sh -f
# veya
python3 app.py
```

### 3. Uygulamayı Durdurma
```bash
./stop.sh
```

---

## Dosya Yapısı

- `app.py`: Menü çubuğu arayüzü ve ana olay döngüsü (`rumps`).
- `key_listener.py`: Global Sağ Command (keycode 54) tuş yakalayıcısı (`pynput`).
- `voice_engine.py`: Bellek içi 16kHz ses kaydedici ve Groq/Gemini deşifre motoru.
- `text_injector.py`: Metni panoya kopyalayıp odaklanılmış metin kutusuna Cmd+V ile yapıştıran motor.
- `sound_effects.py`: macOS yerel ses efektleri yöneticisi (`AppKit.NSSound`).
- `config.py`: Yapılandırma, model tanımları ve .env yöneticisi.
- `start.sh` / `stop.sh`: Başlatma ve durdurma kabuk betikleri.
- `test_suite.py`: Otomatik doğrulama testleri.
