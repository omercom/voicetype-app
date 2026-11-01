# VoiceType 🎙️

**Mac'inizde konuşarak yazın. İsterseniz konuşmanızı çevirin veya seçtiğiniz metni dinleyin.**

VoiceType, macOS menü çubuğunda çalışan açık kaynaklı bir uygulamadır. Mesaj, e-posta veya belge yazarken konuşmanızı metne dönüştürür.

![VoiceType ayarlar penceresi](docs/images/ayarlar.png)

## Neler yapabilir?

- **Konuşarak yazın:** Bir metin alanı seçin, Sağ Command tuşuna basılı tutun ve konuşun.
- **Çevirerek yazın:** Sağ Option ile konuşun; metin seçtiğiniz dile çevrilsin.
- **Metni dinleyin:** Seçili Türkçe metni Mac'inizde seslendirin.
- **Motoru seçin:** Apple Speech, yerel Seda veya desteklenen bulut servislerini kullanın.
- **Çalışmanıza devam edin:** VoiceType arka planda çalışır. Ayarları menü çubuğundan değiştirirsiniz.

## Ücretsiz kullanabilir miyim?

Evet. VoiceType ücretsiz ve açık kaynaklıdır. **Normal dikte için ücretli bir servise veya API anahtarına ihtiyacınız yoktur.**

- **Apple Speech:** macOS ile gelir ve varsayılan olarak seçilidir. Desteklenen cihaz ve dillerde yerel tanıma kullanılır. Diğer durumlarda Apple'ın konuşma tanıma davranışı geçerlidir.
- **Seda-v0.1:** Türkçe konuşmayı Mac'inizde işler. İlk kurulumda model indirilir; sonrasında dikte için bulut servisi ve API anahtarı gerekmez.
- **Groq ve Gemini:** İsteğe bağlı bulut servisleridir. Hesap ve API anahtarı gerektirir. Uygun ücretsiz kotalar hafif kullanım için yeterli olabilir; kota, model erişimi ve fiyatlar değişebilir.

Çevirili dikte şu anda Groq veya Gemini gerektirir. Kullanımınız ücretsiz kotayı aşarsa veya ücretli bir plan seçerseniz sağlayıcınız ücret uygulayabilir. Güncel koşulları [Groq](https://console.groq.com/docs/rate-limits) ve [Gemini](https://ai.google.dev/gemini-api/docs/rate-limits) üzerinden kontrol edin.

## Kurulum

**Gerekenler:** macOS 13 veya daha yeni bir sürüm, mikrofon ve [Xcode Komut Satırı Araçları](https://developer.apple.com/xcode/resources/). Apple Silicon ve Intel Mac'ler desteklenir.

Terminal'i açın ve şu komutları çalıştırın:

```bash
git clone https://github.com/omercom/voicetype-app.git
cd voicetype-app
./install.sh
```

Kurulum uygulamayı Uygulamalar klasörüne yerleştirir ve başlatır. Mac açıldığında da otomatik başlar.

### Uygulama nerede?

VoiceType'ın simgesi ekranın **sağ üstündeki menü çubuğunda**, saat ve Wi-Fi simgelerinin bulunduğu alanda görünür.

Simgeye tıklayarak **Ayarlar**, ses tanıma motoru, seslendirme ve diğer seçeneklere ulaşabilirsiniz. Ayarlarınızı değiştirdiğinizde ayrıca kaydetmeniz gerekmez.

### İzinleri açın

İlk kullanımda macOS'un istediği izinleri onaylayın:

1. **Mikrofon:** Konuşmanızı kaydetmek için.
2. **Erişilebilirlik:** Kısayolu algılamak ve metni seçtiğiniz alana yazmak için.
3. **Konuşma Tanıma:** Yalnızca Apple Speech kullanırken.

İzinlerin durumunu VoiceType → **Ayarlar → İzinler** bölümünden kontrol edebilirsiniz.

## Nasıl kullanılır?

### Konuşarak yazın

1. Mesaj, e-posta, not veya başka bir metin alanına tıklayın.
2. **Sağ Command (⌘)** tuşuna basılı tutun ve konuşun.
3. Bitirdiğinizde tuşu bırakın. VoiceType metni seçtiğiniz alana yapıştırır.

Kayıt sırasında vazgeçmek için **Esc** tuşuna basın. Kısayolu ve diğer davranışları Ayarlar'dan değiştirebilirsiniz.

### Konuşmanızı çevirin

1. Menü çubuğundan **Ayarlar** penceresini açın.
2. **Sağ Option ile Çevir** seçeneğini açın ve hedef dili seçin.
3. Groq veya Gemini API anahtarınızı Ayarlar'a ekleyin.
4. Bir metin alanına tıklayın. **Sağ Option (⌥)** tuşuna basılı tutarak konuşun ve bitince bırakın.

Örneğin Türkçe konuşup İngilizce yazabilirsiniz. İngilizce, Almanca, İspanyolca ve Fransızca hedef diller arasındadır. **Sağ Command** normal dikte yapmaya devam eder.

VoiceType, uygun canlı tanıma sonuçlarında cümleleri konuşma sırasında arka planda çevirmeye başlayabilir. Sonucu tek seferde yapıştırır. Çeviri başarısız olursa özgün metni korur ve sizi uyarır.

### Seçili metni dinleyin

Önce yerel Türkçe ses motorunu kurun. Bunun için [uv](https://docs.astral.sh/uv/getting-started/installation/) ve ilk kurulumda internet gerekir:

```bash
./setup-tts.sh
```

Ardından bir metin seçin ve **Option + Command + S** tuşlarına basın. Aynı kısayol veya **Esc** okumayı durdurur. Menü çubuğundaki **Metni Seslendir** menüsünden panodaki metni de seslendirebilirsiniz.

Ses üretimi Mac'inizde yapılır. İlk kurulumdan sonra seslendirme için bulut API'si gerekmez. Ayrıntılar: [Antalia Mini](experiments/antalia-mini-demo/README.md).

### Türkçe dikteyi tamamen yerel çalıştırın

Seda-v0.1 seçeneğini kullanmak için [uv](https://docs.astral.sh/uv/getting-started/installation/) kurun ve Terminal'de şu komutu çalıştırın:

```bash
./setup-stt.sh
```

Ardından menü çubuğundan **Ses Tanıma → Harfiyen · Seda-v0.1** seçeneğini seçin. Dili **Türkçe (`tr`)** olarak ayarlayın. İlk kurulum model dosyalarını indirir; sonraki dikte işlemleri Mac'inizde çalışır. Tek kayıt en fazla 10 dakika sürer.

Seda bir konuşma tanıma motorudur; metin seslendirme özelliği değildir. Model lisansları ve ayrıntılar için [Seda kurulumuna](runtime/seda/README.md) bakın.

### Chrome'da metin dinleyin

İsteğe bağlı Chrome eklentisi, seçtiğiniz metnin yanında **Oku** düğmesi gösterir. Aynı yerel ses motorunu kullanır. Kurulum ve kullanım adımları: [Chrome eklentisi](browser-extension/README.md).

## Gizlilik

- **Apple Speech:** Desteklenen durumlarda konuşma cihazda işlenir. Diğer durumlarda Apple'ın konuşma tanıma koşulları geçerlidir.
- **Seda ve Antalia Mini:** Kurulum tamamlandıktan sonra ilgili ses tanıma veya seslendirme işlemi Mac'inizde yapılır.
- **Groq, Gemini ve AssemblyAI:** Bu servislerden biri ses tanıma için seçilirse kayıt o servise gönderilir.
- **Çeviri:** Metin Groq veya Gemini'ye gönderilir. Otomatik seçimde Groq başarısız olursa metin yapılandırılmış Gemini'ye de gönderilebilir. Ara cümleler konuşma sürerken gönderilebilir.
- **İzinler:** Erişilebilirlik izni, kısayollar ve metni hedef alana yazmak için kullanılır. API anahtarları kullanıcı hesabındaki yerel ayarlarda saklanır.

Özel içerikleri göndermeden önce seçtiğiniz sağlayıcının gizlilik ve ücret koşullarını kontrol edin. Ayrıntılı bilgi: [dikte ve çeviri kılavuzu](VOICE_TYPING.md).

## Yardım

- **Simge görünmüyor:** Uygulamanın açık olduğunu ve menü çubuğunda yeterli yer bulunduğunu kontrol edin.
- **Kısayol çalışmıyor:** Mikrofon ve Erişilebilirlik izinlerini kontrol edin. Apple Speech için Konuşma Tanıma iznini de açın.
- **Metin yazılmıyor:** Önce düzenlenebilir bir metin alanı seçin. Bazı güvenli alanlar veya uygulamalar otomatik yapıştırmayı sınırlayabilir.
- **Çeviri çalışmıyor:** Çevirinin açık olduğunu, API anahtarını, internet bağlantısını ve sağlayıcı kotasını kontrol edin.

Daha fazla kurulum, gizlilik ve sorun giderme bilgisi için [VoiceType kılavuzuna](VOICE_TYPING.md) bakın.

## Geliştiriciler

```bash
swift test
```

Canlı API ve mikrofon testleri varsayılan olarak kapalıdır. Bunları etkinleştirme koşulları [test kılavuzunda](VOICE_TYPING.md) açıklanır. Deneyler için [experiments](experiments/README.md) klasörüne bakın.

## Lisans ve teşekkür

VoiceType için MIT lisansı belirtilmiştir; depoda henüz ayrı bir lisans dosyası yoktur. Harfiyen, Seda-v0.1 ve Antalia Mini'nin kendi lisansları geçerlidir. Bazı tasarım yaklaşımları için [AlwaysWhisper](https://github.com/kzkhykw/AlwaysWhisper) projesinden yararlanılmıştır.
