# VoiceType için Raycast

Bu yerel Raycast eklentisi, VoiceType diktesini başlatmak veya bitirmek ve ayarları açmak için komutlar sunar. Eklenti henüz Raycast Store'da yayımlanmadı. Raycast ve macOS otomasyon bağlantısı gerçek kullanımda henüz doğrulanmadı.

## Gerekenler

- macOS üzerinde kurulu ve en az bir kez açılmış VoiceType.
- [Raycast](https://www.raycast.com/) ve Node.js 22.22.2 veya daha yeni bir sürüm.
- VoiceType için Mikrofon ve Erişilebilirlik izinleri. Apple Speech kullanıyorsanız Konuşma Tanıma izni de gerekir.

## Kurulum

Proje klasöründe Terminal'i açın:

```bash
cd integrations/raycast
npm ci
npm run dev
```

Raycast'in eklentiyi içe aktarma adımlarını izleyin. İlk komutta macOS, Raycast'in veya AppleScript çalıştırıcısının VoiceType'ı kontrol etmesi için **Otomasyon** izni isteyebilir. İzni yalnızca bu entegrasyonu kullanmak istiyorsanız verin. İzin durumunu **Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon** bölümünden değiştirebilirsiniz.

## Kullanım

1. Yazı yazmak istediğiniz uygulamada bir metin alanı seçin.
2. Raycast'i açın ve **Start VoiceType Dictation** komutunu çalıştırın.
3. Konuşun. Ardından Raycast'te **Stop VoiceType Dictation** komutunu çalıştırın.
4. VoiceType, sonucu kayıt başında seçilen alana yazmaya çalışır.

**Open VoiceType Settings**, uygulamanın ayarlarını açar. Normal Sağ Command kısayolu da çalışmaya devam eder.

Raycast kapandıktan sonra hedef uygulama ve yazı alanı yeniden doğrulanır. Odak başka bir uygulamaya kayarsa veya geçerli bir metin alanı bulunamazsa dikte başlamaz. VoiceType'ın hedef değişikliği ve pano güvenliği ayarları, sonuç yazılırken de geçerlidir.

## Geliştirme

```bash
npm run typecheck
npm test
npm run build
```

Bu entegrasyon, macOS'un Apple Events iznini kullanır. Ağ üzerinden kontrol bağlantısı veya özel URL şeması açmaz. Raycast API örnekleri için [resmî Raycast eklenti deposuna](https://github.com/raycast/extensions) bakın.
