# VoiceType 🎙️ (macOS)

**Mac için tamamen ücretsiz, ışık hızında ve sorunsuz sesle yazma (dikte) uygulaması.**

Google Gemini Live ve Groq Whisper altyapısını kullanarak, sistem genelinde herhangi bir metin alanında (Word, Notlar, Slack, Chrome, VS Code, WhatsApp vb.) klavyeye dokunmadan yalnızca konuşarak yazmanızı sağlar.

---

## ✨ Öne Çıkan Özellikler

* **⚡ Işık Hızında & Sıfır Gecikme:** Google Gemini Live (WebSocket canlı akış) ve Groq Whisper bulut LPU donanımı sayesinde kelimeler siz konuşurken anında işlenir.
* **🇹🇷 Kusursuz Türkçe & Çoklu Dil:** Türkçe ekleri, imla ve noktalama kurallarını eksiksiz uygular. İster Türkçe (`tr`), ister İngilizce (`en`), isterseniz otomatik dil algılama (`auto`) kullanın.
* **💸 %100 Ücretsiz (Kendi API Anahtarınla):** Abonelik veya ücretli planlar yok. Kendi ücretsiz Google Gemini veya Groq API anahtarınızı girin ve sınırsızca kullanın.
* **🎯 Evrensel ve Sorunsuz Yapıştırma:** Tüm Mac uygulamalarında (Electron, Web ve Native) imlecin bulunduğu yere donanım düzeyinde anında yapıştırır.
* **⌨️ Bas-Konuş (Push-to-Talk) Kolaylığı:** Varsayılan **Sağ Command (⌘)** tuşuna basılı tutarak konuşun, bıraktığınız anda metniniz yazılsın.
* **🔇 Konuşurken Müziği Susturma:** Konuşmaya başladığınızda çalan müziği veya medyayı otomatik olarak duraklatır, dikte bitince kaldığı yerden devam ettirir.
* **💎 Minimal Dinamik Ada Tasarımı:** Ekranda yer kaplamayan, zarif ve modern mikro durum göstergesi (Dynamic Island / Siri Pill estetiği).
* **⚙️ Modern macOS Standartları:** Her yaptığınız ayar anında otomatik olarak kaydedilir; karmaşık menüler veya kaydet butonları yoktur.

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

### 2. Ücretsiz API Anahtarınızı Girin

1. Menü çubuğundaki **VoiceType** simgesine tıklayın ve **Ayarlar...** seçeneğini açın.
2. Ücretsiz aldığınız **Google Gemini** veya **Groq** API anahtarınızı yapıştırın.
3. Ayarlar anında otomatik kaydedilir.

*(Mikrofon ve Erişilebilirlik izinlerini Sistem Ayarları'ndan bir defaya mahsus onaylayın).*

---

## 💡 Nasıl Kullanılır?

1. İmlecinizi yazmak istediğiniz yere konumlandırın (örneğin bir mesaj kutusu, arama çubuğu veya belge).
2. Klavyenizdeki **Sağ Command (⌘)** tuşuna basılı tutun ve konuşun.
3. Konuşmanız bittiğinde tuşu bırakın; metniniz imlecin olduğu yere anında yapıştırılır.

---

## 🛠️ Sistem Gereksinimleri

* macOS 13.0+ (Ventura, Sonoma, Sequoia)
* Apple Silicon (M1/M2/M3/M4) veya Intel Mac

---

## 📄 Lisans

MIT License. Tamamen açık kaynak ve ücretsizdir.
