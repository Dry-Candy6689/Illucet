import Foundation

enum AppIdentity {
    static let fallbackDisplayName = "Illucet"
    static let storageDirectoryName = "Illucet"
    static let backgroundSessionIdentifier = "com.local.illucet.downloads"
    static let backgroundProcessingIdentifier = "com.local.illucet.processing"
    static let liveActivityAttributesName = "IllucetProgress"
    static let URLScheme = "illucet"

    static var displayName: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String ?? fallbackDisplayName
    }
}
