import Foundation

/// The two kinds of build. The release app and the development app never share data.
public enum AppVariant: Sendable, Equatable {
    case release
    case development
}

/// The identity of the running app, taken from its bundle ID.
public struct AppIdentity: Sendable, Equatable {
    /// The bundle ID of the development app ends with this text.
    public static let developmentSuffix = ".native-dev"

    public let bundleID: String

    /// Returns nil when the bundle ID is nil or empty.
    /// Also returns nil when the bundle ID is only the development suffix. Then the release part
    /// is empty.
    public init?(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty, bundleID != Self.developmentSuffix else {
            return nil
        }
        self.bundleID = bundleID
    }

    public var variant: AppVariant {
        bundleID.hasSuffix(Self.developmentSuffix) ? .development : .release
    }

    /// The bundle ID of the release app. It has no development suffix.
    package var releaseBundleID: String {
        guard variant == .development else { return bundleID }
        return String(bundleID.dropLast(Self.developmentSuffix.count))
    }

    /// The folder name in Application Support.
    package var supportFolderName: String {
        variant == .development ? "Bifrost Native Dev" : "Bifrost"
    }

    /// The folder name in the home folder.
    package var dotFolderName: String {
        variant == .development ? ".bifrost-native-dev" : ".bifrost"
    }
}
