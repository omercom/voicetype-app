import Foundation

/// Resolves SwiftPM resources from a packaged app without depending on build-machine paths.
enum VoiceTypeResources {
    static func url(
        forResource name: String,
        withExtension fileExtension: String,
        subdirectory: String? = nil,
        mainBundle: Bundle = .main
    ) -> URL? {
        if let bundleURL = mainBundle.url(forResource: "VoiceTyping_VoiceTypingCore", withExtension: "bundle"),
           let resourceBundle = Bundle(url: bundleURL) {
            let resource = resourceBundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            return resource.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }
        }

        // A packaged app with missing resources should not fall back to a build-machine path.
        guard mainBundle.bundleURL.pathExtension != "app" else { return nil }
        #if SWIFT_PACKAGE
        let resource = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
        return resource.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }
        #else
        return nil
        #endif
    }
}
