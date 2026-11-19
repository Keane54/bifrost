import BifrostFoundation

/// Decides if this build of the app may run. The app calls it after the start rule.
///
/// Before cutover, the release app has the bundle ID of the Electron app. If it starts, it can
/// use the data of the Electron app. Thus only the development app may run until cutover.
public enum StartGuard {
    /// The development app may always run. The release app may run only with `cutover`.
    /// The app passes true only when the build sets the condition BIFROST_CUTOVER. No build
    /// configuration sets it before cutover.
    public static func mayStart(variant: AppVariant, cutover: Bool) -> Bool {
        switch variant {
        case .development: true
        case .release: cutover
        }
    }
}
