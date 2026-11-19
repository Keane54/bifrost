import BifrostFoundation

/// A reason why the app must not start.
public enum StartProblem: Sendable, Equatable {
    /// The app has no usable bundle ID. Thus it cannot find its data folders.
    case missingIdentity
    /// A Debug build has a bundle ID without the development suffix. A Debug build must never use
    /// the data folders of the release app.
    case releaseIdentityInDebugBuild
}

/// Decides if the app can start. The app calls this rule before it finds its data folders.
public enum StartRule {
    /// Returns nil when the app can start. Otherwise returns the problem.
    /// A Release build can start with the two identities. The development folders are safe.
    public static func problem(identity: AppIdentity?, isDebugBuild: Bool) -> StartProblem? {
        guard let identity else { return .missingIdentity }
        if isDebugBuild && identity.variant != .development {
            return .releaseIdentityInDebugBuild
        }
        return nil
    }
}
