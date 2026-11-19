import BifrostFoundation

/// Decides if the app starts the updater.
public enum UpdatePolicy {
    /// Returns true only for the release app that has a feed URL and a public key.
    /// The development app never starts the updater. Thus it cannot replace itself with the
    /// release app.
    public static func startsUpdater(
        variant: AppVariant,
        feedURL: String?,
        publicKey: String?
    ) -> Bool {
        guard variant == .release,
              let feedURL, !feedURL.isEmpty,
              let publicKey, !publicKey.isEmpty
        else { return false }
        return true
    }

    /// The error domain of Sparkle (SUSparkleErrorDomain) and the codes of the ends of an update
    /// cycle that are no failure: no new update (SUNoUpdateError), and the user cancelled the
    /// install or chose to install later (SUInstallationCanceledError and
    /// SUInstallationAuthorizeLaterError).
    static let sparkleDomain = "SUSparkleErrorDomain"
    static let goodEndCodes: Set<Int> = [1001, 4007, 4008]

    /// Returns true when an update cycle of Sparkle ended well: with no error, or with an error of
    /// the codes above. Each other error is a failed check of the updates for the health log.
    public static func cycleSucceeded(_ error: (domain: String, code: Int)?) -> Bool {
        guard let error else { return true }
        return error.domain == sparkleDomain && goodEndCodes.contains(error.code)
    }
}
