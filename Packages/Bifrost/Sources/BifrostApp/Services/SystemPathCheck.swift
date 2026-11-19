import BifrostFoundation

extension PathCheck {
    // The check of the app: the file systems of macOS ignore the case, and RealPath gives the
    // real path of a path that exists.
    public static let system = PathCheck(ignoresCase: true) { RealPath.of($0) }
}
