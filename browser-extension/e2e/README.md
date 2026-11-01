# Chrome üzerinden gerçek Antalia testi

[read_aloud.cjs](read_aloud.cjs) kurulu VoiceTyping uygulamasını gerçek Chromium eklentisiyle sınar.
Mock motor kullanmaz. Yerel HTTP sayfası yalnız test metinlerini içerir.
Test hoparlörden ses çalar; çalıştırmadan önce açık okumayı durdurun.

## Gereksinimler

- macOS, Node.js 20 veya üstü ve npm.
- `./setup-tts.sh` ile kurulu Antalia motoru.
- Açık ve güncel VoiceTyping uygulaması.
- İlk kurulumda Playwright ve Chromium indirmeleri için internet.

Komutları proje kökünden çalıştırın:

```sh
npm install --prefix browser-extension/e2e/.deps --no-save --package-lock=false playwright@1.64.0
browser-extension/e2e/.deps/node_modules/.bin/playwright install chromium

# Yalnız test profiline yerel bağlantı kaydı yaz
./setup-chrome.sh --profile "$PWD/browser-extension/e2e/profile"

PLAYWRIGHT_MODULE="$PWD/browser-extension/e2e/.deps/node_modules/playwright" \
VOICETYPE_E2E_PROFILE="$PWD/browser-extension/e2e/profile" \
VOICETYPE_E2E_OUTPUT="$PWD/browser-extension/e2e/output" \
node browser-extension/e2e/read_aloud.cjs
```

`VOICETYPE_E2E_PROFILE` için kişisel Chrome profilinizi kullanmayın.
Test ayrı Chromium profilini görünmez çalıştırır; kişisel sekmeleri değiştirmez.
Native Messaging kaydı yalnız test profiline yazılır.
Kurulum, kullanıcı motorunun mevcut yerel bağlantı betiğini güncel proje sürümüyle eşitler.
Bu testin uygulama ile ortak seslendirme kanalı vardır; mevcut okumayı değiştirebilir.

## Kontroller

1. Paketlenmemiş gerçek eklenti yüklenir.
2. Seçili metin için okuma düğmesi görünür.
3. Gerçek tıklama kurulu uygulamada Antalia üretimini ve oynatmayı başlatır.
4. Duraklatma süreyi ve bölüm bilgisini sabit tutar.
5. `Tab` devam düğmesine ulaşır; `Space` okumayı devam ettirir.
6. Uzun metin ikinci bölümün gerçek oynatma durumuna geçer.
7. Durdur komutu kalan bölümleri iptal eder.
8. Kısa okuma biter; bitiş mesajı görünür kalır.
9. Gerçek WAV dosyaları `0600`, klasörleri `0700` izniyle oluşur ve bitişte temizlenir.
10. Parola seçimi okuma düğmesini göstermez.

Düğmeler kapalı shadow root içindedir.
Test Chromium erişilebilirlik ağacını kullanır; uygulama kaynaklarını değiştirmez.
Başlatma olayları tarayıcının gerçek fare/klavye girdileridir; sentetik DOM tıklaması değildir.

Sonuç ve ekran görüntüleri `output/` altında saklanır.
Test başarısız olursa sahip olduğu okumayı durdurmayı dener ve tarayıcıyı kapatır.
`.deps/`, `profile/` ve `output/` Git dışında tutulur.

UI oynatma durumuna geçiş süresi, hoparlörden ilk ses duyulma süresi değildir.
Bu test ekran okuyucu anonsunu, telaffuzu veya ses doğallığını ölçmez.
