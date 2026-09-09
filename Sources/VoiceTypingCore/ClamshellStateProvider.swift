import Foundation
import IOKit

/// MacBook kapağının (clamshell) kapalı olup olmadığını IOKit üzerinden sorgular.
/// Apple Silicon ve T2 güvenlik yongalı Mac'lerde kapak kapatıldığında donanım
/// gizliliği için dahili mikrofon fiziksel olarak devreden çıkar. Bu sağlayıcı
/// saf sessizlik kaydedilmesini önlemek amacıyla kapak durumunu tespit eder.
public protocol ClamshellStateProviding: AnyObject, Sendable {
    func isLidClosed() -> Bool
}

public final class IOKitClamshellStateProvider: ClamshellStateProviding, @unchecked Sendable {
    public static let shared = IOKitClamshellStateProvider()

    private static let rootDomainServiceName = "IOPMrootDomain"
    private static let clamshellStatePropertyName = "AppleClamshellState"

    public init() {}

    public func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Self.rootDomainServiceName)
        )
        guard service != IO_OBJECT_NULL else {
            return false
        }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            Self.clamshellStatePropertyName as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }

        if let boolVal = property as? Bool {
            return boolVal
        } else if let numVal = property as? NSNumber {
            return numVal.boolValue
        }
        return false
    }
}
