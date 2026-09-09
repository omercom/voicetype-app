import Foundation

/// macOS Globe / Fn Tuşu Sistem Çakışmasını Engelleyen Yönetici.
///
/// macOS varsayılan olarak Fn/Globe tuşuna basıldığında Emoji & Semboller penceresini açar
/// veya klavye giriş kaynağını değiştirir. Bu durum Fn tuşunu bas-konuş veya dikte tuşu
/// olarak kullanırken rahatsız edici açılır pencerelere yol açar.
///
/// Carbon framework'ün `TISGetFnUsageType` ve `TISUpdateFnUsageType` API'lerini kullanarak
/// Fn tuşu tetikleyici olarak seçildiğinde sistem eylemini `0` (Hiçbir Şey Yapma / Do Nothing)
/// seviyesine alır; uygulama kapanırken veya tuş değiştiğinde kullanıcının orijinal tercihini geri yükler.
public final class GlobeKeySuppressor {
    public static let shared = GlobeKeySuppressor()

    private typealias GetFnUsageTypeFunc = @convention(c) () -> Int32
    private typealias UpdateFnUsageTypeFunc = @convention(c) (Int32) -> Void

    private var getFnUsageType: GetFnUsageTypeFunc?
    private var updateFnUsageType: UpdateFnUsageTypeFunc?

    private var originalUsageType: Int32?
    private var isSuppressed: Bool = false
    private let lock = NSLock()

    private init() {
        if let carbonHandle = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY) {
            if let getSym = dlsym(carbonHandle, "TISGetFnUsageType") {
                getFnUsageType = unsafeBitCast(getSym, to: GetFnUsageTypeFunc.self)
            }
            if let updateSym = dlsym(carbonHandle, "TISUpdateFnUsageType") {
                updateFnUsageType = unsafeBitCast(updateSym, to: UpdateFnUsageTypeFunc.self)
            }
        }
    }

    /// Eğer tetikleyici tuş Fn / Globe (63) ise macOS'un varsayılan eylemini geçici olarak '0' (Hiçbir Şey Yapma) yapar.
    public func suppressIfNeeded(triggerKey: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard triggerKey == 63 else {
            // Eğer tetikleyici tuş 63 değilse ama daha önce bastırılmışsa eski haline döndür
            restoreOriginalLocked()
            return
        }

        guard !isSuppressed, let get = getFnUsageType, let update = updateFnUsageType else { return }

        let current = get()
        if current != 0 {
            originalUsageType = current
            update(0) // 0 = Do Nothing
            isSuppressed = true
            print("[GlobeKeySuppressor] 🌐 macOS Globe/Fn sistem eylemi geçici olarak bastırıldı (Önceki: \(current) -> 0).")
        }
    }

    /// Orijinal sistem ayarını geri yükler (Uygulama kapanışında veya tuş değiştirildiğinde).
    public func restoreOriginal() {
        lock.lock()
        defer { lock.unlock() }
        restoreOriginalLocked()
    }

    private func restoreOriginalLocked() {
        guard isSuppressed, let original = originalUsageType, let update = updateFnUsageType else { return }
        update(original)
        print("[GlobeKeySuppressor] 🌐 macOS Globe/Fn sistem eylemi orijinal haline geri yüklendi (\(original)).")
        originalUsageType = nil
        isSuppressed = false
    }

    deinit {
        restoreOriginal()
    }
}
