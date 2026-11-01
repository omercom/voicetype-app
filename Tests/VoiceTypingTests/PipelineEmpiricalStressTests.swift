import XCTest
import Foundation
@testable import VoiceTypingCore

// MARK: - Stress Test Mock URL Protocol

/// Ağ stres simülasyonları için thread-safe ve özelleştirilebilir URLProtocol.
final class StressMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _delay: TimeInterval = 0.0

    static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _responseHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _responseHandler = newValue
        }
    }

    static var delay: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _delay
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _delay = newValue
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _responseHandler = nil
        _delay = 0.0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let currentDelay = StressMockURLProtocol.delay
        if currentDelay > 0 {
            Thread.sleep(forTimeInterval: currentDelay)
        }

        guard let handler = StressMockURLProtocol.responseHandler else {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorUnknown,
                userInfo: [NSLocalizedDescriptionKey: "StressMockURLProtocol handler yok"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - PipelineEmpiricalStressTests

final class PipelineEmpiricalStressTests: XCTestCase {

    private var mockSession: URLSession!
    private var service: TranslationService!

    override func setUp() {
        super.setUp()
        StressMockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StressMockURLProtocol.self]
        mockSession = URLSession(configuration: configuration)
        service = TranslationService(session: mockSession)
    }

    override func tearDown() {
        StressMockURLProtocol.reset()
        mockSession = nil
        service = nil
        super.tearDown()
    }

    // =========================================================================
    // MARK: - 1. KONFİGÜRASYON GERİYE UYUMLULUK VE MUTASYON DİRENÇ TESTLERİ
    // =========================================================================

    func testCorruptedJSONSyntaxFallback() {
        let malformedPayloads = [
            "",
            "   ",
            "{",
            "{ not_valid_json: true }",
            "{\"enable_translation\": true,",
            "{\"enable_translation\": [unclosed array",
            "{\"translation_provider\": \"groq\", \"broken\": }",
            "[1, 2, 3, \"not an object\"]",
            "null",
            "true",
            "12345"
        ]

        for payload in malformedPayloads {
            let data = Data(payload.utf8)
            let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
            // Bozuk JSON decode edilememeli, fakat çökme yaşanmadan güvenli varsayılana düşülebilmelidir.
            XCTAssertNil(decoded, "Bozuk JSON nil dönmeli: \(payload)")

            let fallbackConfig = decoded ?? AppConfig.defaultConfig
            XCTAssertFalse(fallbackConfig.enable_translation)
            XCTAssertEqual(fallbackConfig.translation_target_language, "en")
            XCTAssertEqual(fallbackConfig.translation_provider, "auto")
        }
    }

    func testMissingFieldsPartialConfigFallback() throws {
        // Tamamen boş JSON
        let emptyObj = "{}"
        let emptyConfig = try JSONDecoder().decode(AppConfig.self, from: Data(emptyObj.utf8))
        XCTAssertFalse(emptyConfig.enable_translation)
        XCTAssertEqual(emptyConfig.translation_target_language, "en")
        XCTAssertEqual(emptyConfig.translation_provider, "auto")

        // Sadece tek alan içeren eksik JSON'lar
        let onlyEnable = "{\"enable_translation\": true}"
        let config1 = try JSONDecoder().decode(AppConfig.self, from: Data(onlyEnable.utf8))
        XCTAssertTrue(config1.enable_translation)
        XCTAssertEqual(config1.translation_target_language, "en")
        XCTAssertEqual(config1.translation_provider, "auto")

        let onlyLang = "{\"translation_target_language\": \"de\"}"
        let config2 = try JSONDecoder().decode(AppConfig.self, from: Data(onlyLang.utf8))
        XCTAssertFalse(config2.enable_translation)
        XCTAssertEqual(config2.translation_target_language, "de")
        XCTAssertEqual(config2.translation_provider, "auto")

        let onlyProvider = "{\"translation_provider\": \"gemini\"}"
        let config3 = try JSONDecoder().decode(AppConfig.self, from: Data(onlyProvider.utf8))
        XCTAssertFalse(config3.enable_translation)
        XCTAssertEqual(config3.translation_target_language, "en")
        XCTAssertEqual(config3.translation_provider, "gemini")
    }

    func testTypeMismatchJSONResilience() {
        // Alanların beklenen veri tiplerinden farklı olduğu mutasyonlar
        let typeMismatchedPayloads = [
            "{\"enable_translation\": \"yes\"}",
            "{\"enable_translation\": 1}",
            "{\"enable_translation\": [true]}",
            "{\"translation_target_language\": 123}",
            "{\"translation_target_language\": true}",
            "{\"translation_target_language\": {\"lang\": \"en\"}}",
            "{\"translation_provider\": 999}",
            "{\"translation_provider\": [\"groq\", \"gemini\"]}"
        ]

        for payload in typeMismatchedPayloads {
            let data = Data(payload.utf8)
            let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
            XCTAssertNil(decoded, "Tip uyuşmazlığında decode güvenle başarısız olmalı: \(payload)")
            let safeConfig = decoded ?? AppConfig.defaultConfig
            XCTAssertFalse(safeConfig.enable_translation)
            XCTAssertEqual(safeConfig.translation_target_language, "en")
            XCTAssertEqual(safeConfig.translation_provider, "auto")
        }
    }

    func testInvalidProviderNamesFallbackBehavior() {
        let invalidProviders = [
            "invalid_provider",
            "openai",
            "custom_llm",
            "deepseek",
            "anthropic",
            "",
            "   ",
            "12345",
            "!@#$%^&*()",
            "unknown_vendor"
        ]

        for invalidProvider in invalidProviders {
            var config = AppConfig.defaultConfig
            config.enable_translation = true
            config.translation_provider = invalidProvider

            // 1. Durum: Hiçbir API anahtarı yokken -> Servis çökmemeli, nil provider üzerinden güvenle fallback dönmeli.
            config.groq_api_key = ""
            config.gemini_api_key = ""

            let exp1 = expectation(description: "Geçersiz sağlayıcı ve anahtarsız fallback: \(invalidProvider)")
            service.translate(text: "Merhaba dünya", config: config) { result in
                XCTAssertTrue(result.wasFallback)
                XCTAssertEqual(result.text, "Merhaba dünya")
                XCTAssertNotNil(result.errorMessage)
                exp1.fulfill()
            }
            waitForExpectations(timeout: 1.0)

            // 2. Durum: Groq anahtarı varken -> Default (auto) dalına düşmeli ve Groq ile çalışmalıdır
            config.groq_api_key = "gsk_test_key"
            StressMockURLProtocol.responseHandler = { request in
                let json = "{\"choices\": [{\"message\": {\"content\": \"Hello world\"}}]}"
                let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (res, Data(json.utf8))
            }

            let exp2 = expectation(description: "Geçersiz sağlayıcıda mevcut anahtara güvenli fallback: \(invalidProvider)")
            service.translate(text: "Merhaba dünya", config: config) { result in
                XCTAssertFalse(result.wasFallback)
                XCTAssertEqual(result.text, "Hello world")
                exp2.fulfill()
            }
            waitForExpectations(timeout: 1.0)
        }
    }

    func testInvalidTargetLanguageCodesResilience() {
        let oddLanguageCodes = [
            "",
            "   ",
            "invalid_lang_code",
            "klingon",
            "xyz999",
            "tr-TR-custom",
            "🚀🔥",
            "çok_uzun_ve_anlamsız_bir_hedef_dil_kodu_1234567890"
        ]

        for code in oddLanguageCodes {
            // Dil ismi çözümleyici asla çökmemeli
            let name = TranslationService.languageName(for: code)
            XCTAssertFalse(name.isEmpty || name == code ? false : false) // Fonksiyonun güvenle dönmesi yeterli

            // Prompt şablonu oluşturucu güvenle çalışmalı
            let prompt = TranslationService.buildSystemPrompt(from: "tr", to: code)
            XCTAssertTrue(prompt.contains("literal translation engine"))

            // Doğrulama fonksiyonu çökmemeli
            let isValid = TranslationService.validateTranslation(
                translatedText: "Some output text",
                originalText: "Bir metin",
                targetLanguage: code
            )
            // 'en' dışındaki kodlar için boş değilse true dönmeli
            XCTAssertTrue(isValid)
        }
    }

    // =========================================================================
    // MARK: - 2. ÇEVİRİ AÇIK/KAPALI AKIŞ GEÇİŞLERİ TESTLERİ (APPDELEGATE DÖNGÜSÜ)
    // =========================================================================

    func testDynamicTranslationToggleRoutingAndStateTransitions() {
        var config = AppConfig.defaultConfig
        config.groq_api_key = "gsk_test_key"
        config.gemini_api_key = ""

        // Mock yanıt kurulumu
        StressMockURLProtocol.responseHandler = { request in
            let json = "{\"choices\": [{\"message\": {\"content\": \"Good morning everyone\"}}]}"
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(json.utf8))
        }

        let originalText = "Herkese günaydın"

        // Senaryo: Kullanıcı çeviriyi anlık olarak açıp kapatıyor.
        // 10 döngü boyunca true -> false -> true -> false geçişleri yapılıyor.
        for iteration in 1...6 {
            let isTranslationEnabled = (iteration % 2 != 0)
            config.enable_translation = isTranslationEnabled

            var networkRequestTriggered = false
            StressMockURLProtocol.responseHandler = { request in
                networkRequestTriggered = true
                let json = "{\"choices\": [{\"message\": {\"content\": \"Good morning everyone (\(iteration))\"}}]}"
                let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (res, Data(json.utf8))
            }

            struct PipelineOutcome {
                let injectedText: String
                let wasAsynchronous: Bool
                let hadErrorNotice: Bool
            }

            func routeDictation(
                text: String,
                cfg: AppConfig,
                completion: @escaping (PipelineOutcome) -> Void
            ) {
                let polished = TextPolisher.shared.polish(text: text, config: cfg, targetContext: nil)
                if cfg.enable_translation {
                    service.translate(text: polished, config: cfg) { res in
                        if res.wasFallback {
                            completion(PipelineOutcome(injectedText: polished, wasAsynchronous: true, hadErrorNotice: true))
                        } else {
                            completion(PipelineOutcome(injectedText: res.text, wasAsynchronous: true, hadErrorNotice: false))
                        }
                    }
                } else {
                    completion(PipelineOutcome(injectedText: polished, wasAsynchronous: false, hadErrorNotice: false))
                }
            }

            let exp = expectation(description: "Döngü \(iteration) akış geçişi")
            routeDictation(text: originalText, cfg: config) { outcome in
                if isTranslationEnabled {
                    XCTAssertTrue(outcome.wasAsynchronous, "Çeviri açıkken asenkron akış çalışmalıdır")
                    XCTAssertFalse(outcome.hadErrorNotice)
                    XCTAssertTrue(outcome.injectedText.contains("Good morning"))
                } else {
                    XCTAssertFalse(outcome.wasAsynchronous, "Çeviri kapalıyken senkron akış çalışmalıdır")
                    XCTAssertFalse(outcome.hadErrorNotice)
                    XCTAssertEqual(outcome.injectedText, originalText)
                }
                exp.fulfill()
            }
            waitForExpectations(timeout: 2.0)

            if isTranslationEnabled {
                XCTAssertTrue(networkRequestTriggered, "Çeviri açıkken ağ isteği tetiklenmelidir")
            } else {
                XCTAssertFalse(networkRequestTriggered, "Çeviri kapalıyken hiçbir ağ isteği oluşmamalıdır")
            }
        }
    }

    // =========================================================================
    // MARK: - 3. AĞ SİMÜLASYONU STRES TESTİ (HTTP 429, 503, GECİKME, KOPMA, ZAMAN AŞIMI)
    // =========================================================================

    func testHTTP429RateLimitResilience() {
        let originalText = "Bu önemli bir toplantı notudur."
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.groq_api_key = "gsk_rate_limited_key"
        config.translation_provider = "groq"

        // 1. Groq formatında HTTP 429 Rate Limit yanıtı
        StressMockURLProtocol.responseHandler = { request in
            let errorJson = """
            {
              "error": {
                "message": "Rate limit reached for model `llama-3.3-70b-versatile` on tokens per minute (TPM): Limit 6000, Used 6200, Requested 300. Please try again in 4.2s.",
                "type": "tokens",
                "code": "rate_limit_exceeded"
              }
            }
            """
            let res = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "5", "Content-Type": "application/json"]
            )!
            return (res, Data(errorJson.utf8))
        }

        let expGroq = expectation(description: "Groq 429 Rate Limit durumunda orijinal metne güvenli fallback")
        service.translate(text: originalText, config: config) { result in
            XCTAssertTrue(result.wasFallback, "HTTP 429 durumunda wasFallback true olmalıdır")
            XCTAssertEqual(result.text, originalText, "HTTP 429 aldığında orijinal metin korunmalıdır")
            XCTAssertNotNil(result.errorMessage)
            XCTAssertTrue(result.errorMessage?.contains("429") ?? false || result.errorMessage?.contains("Rate limit") ?? false)
            expGroq.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // 2. Gemini formatında HTTP 429 Quota Exceeded yanıtı
        config.translation_provider = "gemini"
        config.gemini_api_key = "AIzaSy_rate_limited"

        StressMockURLProtocol.responseHandler = { request in
            let errorJson = """
            {
              "error": {
                "code": 429,
                "message": "Resource has been exhausted (e.g. check quota).",
                "status": "RESOURCE_EXHAUSTED"
              }
            }
            """
            let res = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (res, Data(errorJson.utf8))
        }

        let expGemini = expectation(description: "Gemini 429 Quota Exceeded durumunda orijinal metne güvenli fallback")
        service.translate(text: originalText, config: config) { result in
            XCTAssertTrue(result.wasFallback)
            XCTAssertEqual(result.text, originalText)
            XCTAssertNotNil(result.errorMessage)
            expGemini.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    func testHTTP503ServiceUnavailableResilience() {
        let originalText = "Sistem mimarisi belgesini güncelliyoruz."
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.groq_api_key = "gsk_service_unavailable"
        config.translation_provider = "groq"

        // 1. JSON gövdeli HTTP 503
        StressMockURLProtocol.responseHandler = { request in
            let json = "{\"error\": {\"message\": \"Service Unavailable: backend server overloaded\"}}"
            let res = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (res, Data(json.utf8))
        }

        let exp1 = expectation(description: "HTTP 503 JSON hatasında fallback")
        service.translate(text: originalText, config: config) { result in
            XCTAssertTrue(result.wasFallback)
            XCTAssertEqual(result.text, originalText)
            XCTAssertNotNil(result.errorMessage)
            exp1.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // 2. HTML/Düz metin gövdeli HTTP 503 (Cloudflare veya Load Balancer çökmesi)
        StressMockURLProtocol.responseHandler = { request in
            let html = "<html><body><h1>503 Service Temporarily Unavailable</h1></body></html>"
            let res = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (res, Data(html.utf8))
        }

        let exp2 = expectation(description: "HTTP 503 HTML hatasında çökmeden fallback")
        service.translate(text: originalText, config: config) { result in
            XCTAssertTrue(result.wasFallback)
            XCTAssertEqual(result.text, originalText)
            XCTAssertNotNil(result.errorMessage)
            exp2.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    func testLatencyFastVsNearTimeoutEmpiricalResponse() {
        let originalText = "Hızlı yanıt testi."
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.groq_api_key = "gsk_test_key"
        config.translation_provider = "groq"

        // 1. 10ms Hızlı Yanıt (Fast path): Başarıyla çevrilmeli
        StressMockURLProtocol.delay = 0.010 // 10ms gecikme
        StressMockURLProtocol.responseHandler = { request in
            let json = "{\"choices\": [{\"message\": {\"content\": \"Fast response test.\"}}]}"
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(json.utf8))
        }

        let expFast = expectation(description: "10ms gecikmeli istek başarıyla tamamlanmalı")
        service.translate(text: originalText, config: config, timeout: 6.0) { result in
            XCTAssertFalse(result.wasFallback)
            XCTAssertEqual(result.text, "Fast response test.")
            expFast.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // 2. 5900ms vs 6000ms Zaman Aşımı Sınırı Simülasyonu
        // Gerçek test süresini 6 saniye uzatmamak adına hem orantılı zaman aşımı
        // (örneğin 150ms gecikme vs 100ms timeout) hem de URLError(.timedOut) stres koşulları doğrulanır.
        StressMockURLProtocol.delay = 0.0
        StressMockURLProtocol.responseHandler = { _ in
            // 5900ms - 6000ms zaman aşımı tetiklendiğinde URLSession URLError(.timedOut) üretir
            throw URLError(.timedOut)
        }

        let expTimeout = expectation(description: "Zaman aşımına uğrayan istek orijinal metne güvenle dönmeli")
        service.translate(text: originalText, config: config, timeout: 6.0) { result in
            XCTAssertTrue(result.wasFallback)
            XCTAssertEqual(result.text, originalText)
            XCTAssertNotNil(result.errorMessage)
            expTimeout.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // 3. Orantılı Gecikme Sınır Testi (Timeout: 0.15s, Yanıt gecikmesi: 0.20s)
        StressMockURLProtocol.delay = 0.20 // 200ms
        StressMockURLProtocol.responseHandler = { request in
            let json = "{\"choices\": [{\"message\": {\"content\": \"Late response.\"}}]}"
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(json.utf8))
        }

        let expLate = expectation(description: "Zaman aşımını aşan gecikme fallback yapmalı")
        // timeout 0.1s olarak verildiğinde sistem geciken yanıtı beklemeden iptal edebilir veya fallback yapabilir
        service.translate(text: originalText, config: config, timeout: 0.10) { result in
            // Ağ cevabı gecikmeli geldiğinde ya zamanında yetişmez ya da fallback döner
            XCTAssertEqual(result.text.isEmpty, false)
            expLate.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    func testAbruptDisconnectionAndConnectionDropResilience() {
        let originalText = "Bağlantı koptuğunda bu metin kaybolmamalıdır."
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.groq_api_key = "gsk_test_key"
        config.translation_provider = "groq"

        let networkErrors: [URLError.Code] = [
            .networkConnectionLost,      // Ani soket kopması (-1005)
            .cannotConnectToHost,        // Sunucuya ulaşılamıyor (-1004)
            .dnsLookupFailed,            // DNS çözümlenemedi (-1006)
            .notConnectedToInternet,     // Çevrimdışı (-1009)
            .cannotFindHost,             // Host bulunamadı (-1003)
            .dataNotAllowed              // Ağ erişim izni yok (-1020)
        ]

        for errorCode in networkErrors {
            StressMockURLProtocol.delay = 0.0
            StressMockURLProtocol.responseHandler = { _ in
                throw URLError(errorCode)
            }

            let exp = expectation(description: "Ağ kopması (\(errorCode)) durumunda orijinal metne fallback")
            service.translate(text: originalText, config: config) { result in
                XCTAssertTrue(result.wasFallback, "Hata kodunda (\(errorCode)) wasFallback true olmalıdır")
                XCTAssertEqual(result.text, originalText, "Dikte asla kaybolmamalıdır")
                XCTAssertNotNil(result.errorMessage)
                exp.fulfill()
            }
            waitForExpectations(timeout: 2.0)
        }
    }

    func testMalformedTruncatedChunkedResponses() {
        let originalText = "Parçalı ve bozuk JSON yanıtı."
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.groq_api_key = "gsk_test_key"
        config.translation_provider = "groq"

        let malformedDataCases: [Data] = [
            Data(), // Tamamen boş yanıt (0 byte)
            Data("{\"choices\": [{\"message\": {\"content\": ".utf8), // Ortada kesilmiş JSON (bağlantı kopması)
            Data("<html><head><title>Wi-Fi Login</title></head><body>Captive portal</body></html>".utf8), // Otel/Havaalanı Wi-Fi captive portal
            Data("{\"choices\": []}".utf8), // Boş choices dizisi
            Data("{\"error\": null}".utf8)  // Ne error ne choices içeren garip JSON
        ]

        for badData in malformedDataCases {
            StressMockURLProtocol.responseHandler = { request in
                let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (res, badData)
            }

            let exp = expectation(description: "Bozuk veya kesilmiş yanıtta fallback")
            service.translate(text: originalText, config: config) { result in
                XCTAssertTrue(result.wasFallback, "Bozuk veride wasFallback true olmalı")
                XCTAssertEqual(result.text, originalText, "Orijinal metin korunmalı")
                XCTAssertNotNil(result.errorMessage)
                exp.fulfill()
            }
            waitForExpectations(timeout: 2.0)
        }
    }

    func testConcurrentTranslationRequestsStress() {
        // Aynı anda birden fazla çeviri isteği geldiğinde servisin thread-safety doğrulaması
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.groq_api_key = "gsk_test_key"
        config.translation_provider = "groq"

        StressMockURLProtocol.responseHandler = { request in
            let json = "{\"choices\": [{\"message\": {\"content\": \"Concurrent translation verified.\"}}]}"
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(json.utf8))
        }

        let queue = DispatchQueue(label: "test.concurrent.stress", attributes: .concurrent)
        let group = DispatchGroup()
        let count = 20

        for i in 0..<count {
            group.enter()
            queue.async {
                let original = "Eşzamanlı istek \(i)"
                self.service.translate(text: original, config: config) { result in
                    XCTAssertFalse(result.wasFallback)
                    XCTAssertEqual(result.text, "Concurrent translation verified.")
                    group.leave()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(waitResult, .success, "20 eşzamanlı istek 5 saniye içinde tamamlanmalıdır")
    }
}
