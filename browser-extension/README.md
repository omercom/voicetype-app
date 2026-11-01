# Chrome'da VoiceType ile seslendir

Web sayfasında metin seçince yanında **🔊 Oku** butonu görünür.
Butona tıklayınca kurulu VoiceTyping uygulaması metni Antalia Mini ile yerelde okur.
Ses hazırlanırken ve çalarken aynı buton **⏸ Duraklat** olur.
Duraklatınca buton **▶ Devam et** olur. Ayrı **■ Durdur** butonu okumayı tamamen iptal eder.
Buton karakter sayısını, geçen süreyi ve okunan bölümü gösterir.
Uzun metin yaklaşık 350 karakterlik bölümlerle okunur; bütün metnin ses üretimini beklemez.

## Kurulum

Önce proje klasöründen uygulamayı ve motoru kurun:

```sh
VOICETYPE_SETUP_TTS=1 ./install.sh
./setup-chrome.sh
```

Motor zaten kuruluysa `./install.sh` ve `./setup-chrome.sh` yeterlidir.

1. Chrome'da `chrome://extensions` sayfasını açın.
2. **Geliştirici modu** seçeneğini açın.
3. **Paketlenmemiş öğe yükle** seçeneğine basın.
4. Bu projenin `browser-extension/chrome` klasörünü seçin.
5. Açık web sayfalarını yenileyin.
6. Bir Türkçe cümle seçip **🔊 Oku** butonuna basın.

Eklenti kimliği: `nhbnnebmgoemjnaiglhnddflibjofcgd`.
Kurulum yalnız bu kimlik için Native Messaging izni verir.
Manifest içindeki sabit public key, paketlenmemiş eklentinin kimliğini korur.
Bu anahtar gizli bir kimlik doğrulama anahtarı değildir.

Kurulum Google Chrome ve Chrome for Testing için kullanıcı hesabına yerel bağlantı kaydı yazar.
Eklenti Chrome Web Store'a yüklenmemiştir.
Kullanıcının normal Chrome profilinde eklenti yükleme adımı elle yapılır.

## Kullanım

- Metin seçin ve **🔊 Oku** butonuna tıklayın.
- **⏸ Duraklat** butonuyla okumaya ara verin.
- **▶ Devam et** aynı ses konumundan devam eder; metni baştan üretmez.
- Hazırlık sırasında duraklatırsanız hazır ses, **▶ Devam et** komutunu bekler.
- Ayrı **■ Durdur** butonu okumayı ve kalan bölümleri tamamen iptal eder.
- Chrome araç çubuğundaki eklenti simgesi seçim butonuna klavye odağı verir.
- Odaklanan butonu `Enter` veya `Space` ile kullanın.
- VoiceType menüsünden veya **⌥⌘S / Esc** ile de okumayı durdurabilirsiniz.
- Uygulama kapalıysa yerel bağlantı uygulamayı açmayı dener.
- Dikte sırasında seslendirme başlamaz. Yeni dikte mevcut okumayı durdurur.

Arayüz **İstek gönderiliyor**, **Antalia Mini yükleniyor**, **Ses hazırlanıyor**, **Türkçe okunuyor** ve **Okuma duraklatıldı** durumlarını gösterir.
Okuma sırasında **Bölüm 1/20** gibi gerçek bölüm bilgisi görünür.
İlerleme çubuğu tamamlanan bölümleri gösterir; ses üretimi için tahminî yüzde göstermez.
Duraklatırken geçen süre ve bölüm ilerlemesi sabit kalır.
Hata ve bitiş mesajları aynı seçimde kalır. Yeni seçim mesajı sıfırlar.

Yeni okuma önceki okumayı değiştirir.
Eski sekmedeki kontroller yeni sekmenin okumasını durduramaz, duraklatamaz veya devam ettiremez.
Sekme kapanınca veya başka sayfaya geçince ses uygulamada devam edebilir.

## Kapsam ve gizlilik

- Buton yalnız normal HTTP/HTTPS sayfalarında çalışır.
- Seçimin kendisi sesi başlatmaz. Gerçek kullanıcı tıklaması gerekir.
- Yalnız seçili metin gönderilir. Tam sayfa, URL ve pano gönderilmez.
- Parola, kart ve tek kullanımlık kod alanları dışlanır.
- Site yazarı özel bölümlere `data-voicetype-private` ekleyebilir.
- Gizli olduğu işaretlenmeyen normal metnin hassas olduğunu eklenti anlayamaz.
- Metin buluta gönderilmez, günlüğe yazılmaz ve eklenti tarafından saklanmaz.
- Üretilen WAV normal bitişte veya iptalde silinir. Zorla kapanma dosya bırakabilir.
- Bir istekte 1–30.000 Unicode karakter kabul edilir. Model tek Türkçe ses kullanır.
- Sınırı aşan seçimde karakter sayısı ve küçültme uyarısı görünür; ses başlatılmaz.
- İlk kullanım model hazırlığını bekleyebilir. Uygulama hazır modeli tekrar kullanır.
- Chrome iç sayfaları, Web Store, PDF görüntüleyici, iframe ve bazı özel kontroller desteklenmez.
- Gizli modda eklenti varsayılan olarak kapalıdır. Açmak kullanıcının kararıdır.

`nativeMessaging` izni kurulu VoiceTyping uygulamasına bağlanır.
HTTP/HTTPS content script erişimi seçim butonunu sayfa içine ekler.
Eklenti keyfî shell komutu veya URL çalıştırmaz.
Yerel uygulama bağlantısı TCP portu açmaz; aynı kullanıcıya ait özel Unix socket kullanır.

## Sorun giderme

**Buton görünmüyor:** Sayfayı yenileyin, normal bir web sayfasında metin seçin ve eklentinin açık olduğunu kontrol edin.

**Bağlantı kurulamadı:** VoiceTyping uygulamasını açın ve `./setup-chrome.sh` komutunu yeniden çalıştırın.
Menüde Antalia Mini durumunun hazır olduğunu kontrol edin.
Proje veya Python kurulumu taşındıysa yerel bağlantıyı yeniden kurun.

**Eklenti güncellendi:** `chrome://extensions` içindeki eklentiyi yeniden yükleyin ve sayfayı yenileyin.
Yerel bağlantı kodu değiştiyse `./setup-chrome.sh` komutunu da çalıştırın.

**Uzun metinde eski davranış sürüyor:** Uygulama ve yerel bağlantıyı `./install.sh` ve `./setup-chrome.sh` ile güncelleyin.
Eklentiyi yeniden yükleyin; sürümün **1.2.0** olduğunu kontrol edin ve açık sayfayı yenileyin.

## Testler

```sh
VOICETYPE_TEST_ANTALIA=1 swift test
python3 -m unittest discover -s browser-extension -p 'test_*.py' -v
node --test browser-extension/test_*.cjs
```

Önceki EMA sürümünde Chrome 154.0.8037.98 ile ayrı test profilinde gerçek paketlenmemiş eklenti yüklemesi doğrulandı.
Seçim, kullanıcı tıklaması, Native Messaging, EMA ses üretimi, oynatma ve durdurma birlikte test edildi.
Parola, kart, özel DOM alanı ve sentetik tıklama engelleri de doğrulandı.
6.639 karakterlik seçim, bölüm ilerlemesi, ikinci bölüme geçiş ve kalıcı bitiş mesajı doğrulandı.
Duraklatırken sabit kalan süre ve bölüm bilgisi, `Space` ile devam etme ve duraklatılmış okumayı durdurma doğrulandı.
30.000 karakter sınırı üzerindeki hata tıklama ve seçim olaylarından sonra görünür kaldı.
Test, kişisel Chrome profilini değiştirmedi.

Antalia geçişinde Swift gerçek model testi, bölüm oynatma testleri ve Python/Node bağlantı testleri yeniden çalıştırıldı.
9 Ekim 2026'da Playwright 1.64.0 ve Chromium 156.0.8078.4 ile gerçek eklenti uçtan uca testi geçti.
Test kurulu Antalia uygulamasını kullandı; kişisel Chrome profilini değiştirmedi.
Okuma, duraklatma, `Tab`/`Space` ile devam, ikinci bölüm, durdurma ve normal bitiş doğrulandı.
Parola alanı engeli, WAV erişim izinleri ve bitiş/iptal sonrası dosya temizliği doğrulandı.
[Tekrarlanabilir canlı test rehberi](e2e/README.md) kurulum ve çalıştırma komutlarını içerir.
