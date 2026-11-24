import BifrostFoundation

// The calls that a request round and a conflict round make back to their coordinator. One
// value holds them, so both rounds take the same hooks.
struct RoundHooks {
    // The login of the user, or nil when nobody is logged in.
    let viewer: () -> String?
    // True when the user stopped the round with Stop session.
    let stopRequested: () -> Bool
    // True once for a repository that the user did not trust yet and that may start one time.
    let takeTryOnce: () -> Bool
    // The round started a session in the repository.
    let startedSession: () -> Void
    // The state changed, so the views read it again.
    let changed: () -> Void
}
