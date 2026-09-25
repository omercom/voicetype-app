import Foundation

/// Konuşma kapısının durumu.
public enum SpeechGateState: Equatable {
    /// Eşiğin altında, konuşma yok.
    case silent
    /// Konuşma başladı ve sürüyor.
    case speech
    /// Konuşma bitti ama sessizlik henüz `silenceHold` süresini doldurmadı.
    /// Bu durumda segment kapatılmaz: cümle ortasındaki doğal duraklama
    /// konuşmayı ikiye bölmez.
    case holding
}

/// Çift eşikli (hysteresis) konuşma kapısı — saf durum makinesi.
///
/// Tek eşikli bir kapının sorunu: konuşma seviyesi eşiğin etrafında salınırken
/// durum hızla açılıp kapanır ve cümleler hece sınırlarında parçalanır. Çözüm
/// AlwaysWhisper'dan uyarlanan hysteresis: konuşmayı **başlatan** eşik yüksek,
/// konuşmayı **sürdüren** eşik onun yarısı (`STAY_GATE_RATIO = 0.5`).
///
/// Giriş eşiği ayrıca adaptif gürültü tabanına bağlanır
/// (`max(noiseFloor * 4, gateFloor)`): sessiz bir odada fısıltı bile konuşma
/// açar, gürültülü bir odada ise ortam gürültüsü kendiliğinden açmaz.
///
/// Sınıf tamamen deterministiktir: zaman ve güç dışarıdan verilir, içeride
/// duvar saati okunmaz. Bu sayede birim testlerinde `now` doğrudan enjekte
/// edilebilir (RecordingHUD/MicrophoneFeedbackTracker ile aynı yaklaşım).
public struct SpeechGate {

    /// Giriş eşiğinin mutlak tabanı (dBFS). AlwaysWhisper `GATE_DEFAULT`
    /// ~-44 dBFS kullanır; burada uyarı eşiklerimizle (lowLevel -52 dB)
    /// çakışmaması için biraz daha aşağıda tutulur.
    public static let defaultGateFloorDB: Float = -60.0

    /// Sürdürme eşiği oranı: konuşma başladıktan sonra eşik bu orana iner.
    public static let defaultStayRatio: Float = 0.5

    /// Konuşmanın geçerli sayılması için gereken en kısa süre.
    public static let defaultMinSpeechSeconds: TimeInterval = 0.12

    /// Konuşma bittikten sonra segmenti kapatmadan önce beklenecek sessizlik.
    /// AlwaysWhisper `SILENCE_SEC_DEFAULT`.
    public static let defaultSilenceHoldSeconds: TimeInterval = 0.4

    /// Kesintisiz konuşmada segmentin zorla kapatılacağı en uzun süre.
    /// AlwaysWhisper `MAX_SEC_DEFAULT`.
    public static let defaultMaxSegmentSeconds: TimeInterval = 8.0

    /// Kayıt başında ortam gürültüsünü öğrenmek için ayrılan süre.
    ///
    /// Bu pencere olmadan adaptif taban işe yaramaz: ortam gürültüsü mutlak
    /// tabanın üstündeyse kapı hemen açılır ve taban hiç öğrenilemez. Kalibrasyon
    /// sırasında konuşma ilan edilmez, yalnızca taban ölçülür.
    public static let defaultCalibrationSeconds: TimeInterval = 0.5

    /// Gürültü tabanı EMA katsayıları (yalnızca konuşma sayılmayan karelerde).
    private static let noiseFloorAttack: Float = 0.02
    private static let noiseFloorRelease: Float = 0.02

    public let gateFloorDB: Float
    public let stayRatio: Float
    public let minSpeechSeconds: TimeInterval
    public let silenceHoldSeconds: TimeInterval
    public let maxSegmentSeconds: TimeInterval
    public let calibrationSeconds: TimeInterval

    public private(set) var state: SpeechGateState = .silent
    /// Konuşmanın başladığı an (segment başı), yoksa nil.
    public private(set) var speechStartedAt: TimeInterval?
    /// Konuşmanın bittiği an (segment sonu), yoksa nil.
    public private(set) var speechEndedAt: TimeInterval?
    /// Adaptif gürültü tabanı (dBFS).
    public private(set) var noiseFloorDB: Float

    private var lastUpdateAt: TimeInterval?
    /// Kayıt oturumunun başlangıcı (kalibrasyon penceresi için).
    private var sessionStartedAt: TimeInterval?
    /// Kalibrasyon boyunca toplanan güç örnekleri (ortalama için).
    private var calibrationSum: Float = 0
    private var calibrationCount: Int = 0

    public init(
        gateFloorDB: Float = SpeechGate.defaultGateFloorDB,
        stayRatio: Float = SpeechGate.defaultStayRatio,
        minSpeechSeconds: TimeInterval = SpeechGate.defaultMinSpeechSeconds,
        silenceHoldSeconds: TimeInterval = SpeechGate.defaultSilenceHoldSeconds,
        maxSegmentSeconds: TimeInterval = SpeechGate.defaultMaxSegmentSeconds,
        calibrationSeconds: TimeInterval = SpeechGate.defaultCalibrationSeconds,
        initialNoiseFloorDB: Float = -70.0
    ) {
        self.gateFloorDB = gateFloorDB
        self.stayRatio = stayRatio
        self.minSpeechSeconds = minSpeechSeconds
        self.silenceHoldSeconds = silenceHoldSeconds
        self.maxSegmentSeconds = maxSegmentSeconds
        self.calibrationSeconds = calibrationSeconds
        self.noiseFloorDB = initialNoiseFloorDB
    }

    // MARK: - Eşikler

    /// Konuşmayı başlatan eşik: adaptif taban ile mutlak tabanın yükseği.
    public var enterThresholdDB: Float {
        max(noiseFloorDB + 6.0, gateFloorDB)
    }

    /// Konuşmayı sürdüren eşik: giriş eşiğinin `stayRatio` katı, dB uzayında.
    ///
    /// Doğrusal oranı dB'ye çeviriyoruz: `20 * log10(0.5) ≈ -6 dB`. Yani
    /// sürdürme eşiği giriş eşiğinden ~6 dB aşağıdadır — konuşma başladıktan
    /// sonra daha sessiz devam etse de segment kapanmaz.
    public var stayThresholdDB: Float {
        let ratio = min(1.0, max(0.01, stayRatio))
        let offsetDB = 20.0 * log10(ratio)   // stayRatio=0.5 → ~-6.02 dB
        return enterThresholdDB + offsetDB
    }

    // MARK: - Güncelleme

    /// Kapıyı yeni bir güç örneğiyle ilerletir ve güncel durumu döner.
    ///
    /// - Parameters:
    ///   - powerDB: Anlık mikrofon gücü, dBFS (ör. -160…0). NaN/∞ güvenli:
    ///     sessizlik olarak değerlendirilir.
    ///   - now: Monoton saat okuması (saniye).
    ///   - isRecording: Kayıt aktif değilse kapı sıfırlanır.
    @discardableResult
    public mutating func update(
        powerDB: Float,
        now: TimeInterval,
        isRecording: Bool = true
    ) -> SpeechGateState {
        guard isRecording else {
            reset()
            return state
        }

        let power = powerDB.isFinite ? powerDB : -160.0
        lastUpdateAt = now
        if sessionStartedAt == nil { sessionStartedAt = now }

        // Kalibrasyon: kaydın ilk anlarında yalnızca ortam gürültüsünü öğren.
        // Konuşma ilan edilmez; aksi halde gürültülü bir odada kapı anında
        // açılır ve taban hiç öğrenilemez (adaptif eşik işlevsiz kalırdı).
        // Yavaş EMA burada işe yaramaz (0.5 sn'de yalnızca birkaç dB ilerler),
        // bu yüzden kalibrasyon boyunca doğrudan ortalama alınır.
        if let started = sessionStartedAt, now - started < calibrationSeconds {
            calibrationSum += power
            calibrationCount += 1
            noiseFloorDB = min(-20.0, max(-90.0, calibrationSum / Float(calibrationCount)))
            return state
        }

        switch state {
        case .silent:
            // Sessizken gürültü tabanını yavaşça öğren.
            adaptNoiseFloor(towards: power)

            if power >= enterThresholdDB {
                // Aday konuşma: minSpeechSeconds dolmadan "speech" demeyiz,
                // böylece tek karelik sıçramalar konuşma sayılmaz.
                if speechStartedAt == nil {
                    speechStartedAt = now
                } else if now - (speechStartedAt ?? now) >= minSpeechSeconds {
                    state = .speech
                    speechEndedAt = nil
                }
            } else {
                speechStartedAt = nil
            }

        case .speech, .holding:
            let elapsed = speechStartedAt.map { now - $0 } ?? 0

            // Kesintisiz konuşmada segmenti zorla kapat (AlwaysWhisper max_sec).
            // Bu kontrol ÖNCE yapılmalı: aksi halde hiç susmayan bir konuşmacı
            // sürdürme eşiğinin üstünde kaldığı sürece tavan hiç tetiklenmez
            // ve tek segment sonsuza kadar büyür.
            if elapsed >= maxSegmentSeconds {
                closeSegment(at: now)
                // Konuşma hâlâ sürüyorsa hemen yeni bir segment aç; böylece
                // cümlenin kalanı kaybolmaz, yalnızca segment bölünür.
                if power >= stayThresholdDB {
                    speechStartedAt = now
                    speechEndedAt = nil
                    state = .speech
                }
                return state
            }

            if power >= stayThresholdDB {
                // Sürdürme eşiğinin üstünde: konuşma devam ediyor.
                state = .speech
                speechEndedAt = nil
            } else {
                if speechEndedAt == nil { speechEndedAt = now }
                let quietFor = now - (speechEndedAt ?? now)
                if quietFor >= silenceHoldSeconds {
                    closeSegment(at: now)
                } else {
                    state = .holding
                }
            }
        }

        return state
    }

    /// Konuşma segmentini kapatır ve durumu sessizliğe döndürür.
    private mutating func closeSegment(at now: TimeInterval) {
        state = .silent
        speechStartedAt = nil
        speechEndedAt = now
    }

    /// Gürültü tabanını yalnızca konuşma yokken, yavaş bir EMA ile günceller.
    /// Konuşma sırasında taban güncellenmez; aksi halde konuşmanın kendisi
    /// tabanı yükseltir ve kapı kendi kendini sağırlaştırır.
    private mutating func adaptNoiseFloor(towards power: Float) {
        guard power.isFinite else { return }
        let coefficient = power > noiseFloorDB ? Self.noiseFloorAttack : Self.noiseFloorRelease
        noiseFloorDB += (power - noiseFloorDB) * coefficient
        // Tabanı mantıklı bir aralıkta tut.
        noiseFloorDB = min(-20.0, max(-90.0, noiseFloorDB))
    }

    /// Kapıyı başlangıç durumuna döndürür (yeni kayıt oturumu).
    public mutating func reset() {
        state = .silent
        speechStartedAt = nil
        speechEndedAt = nil
        lastUpdateAt = nil
        sessionStartedAt = nil
        calibrationSum = 0
        calibrationCount = 0
        // Gürültü tabanı bilerek korunur: odanın gürültüsü oturumlar arasında
        // değişmez, her kayıtta yeniden öğrenmek gereksiz gecikme yaratır.
        // Yeni oturumun ilk anlarındaki kalibrasyon yine de çalışır ve
        // ortam değiştiyse tabanı hızla günceller.
    }

    /// Kayıt başında gürültü tabanını da sıfırlamak için.
    public mutating func resetFully() {
        reset()
        noiseFloorDB = -70.0
    }

    /// Şu an konuşma var mı (holding dahil: segment henüz kapanmadı).
    public var isSpeechActive: Bool {
        state != .silent
    }

    /// Son güncellemede konuşma henüz hiç başlamadı mı.
    /// HUD'nin "Henüz ses algılanmadı" uyarısı bunu kullanır.
    public var hasNeverSpoken: Bool {
        state == .silent && speechEndedAt == nil
    }
}
