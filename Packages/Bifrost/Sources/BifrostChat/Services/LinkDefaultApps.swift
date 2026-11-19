import BifrostFoundation
import Foundation
import Synchronization

// The apps of Launch Services for the link rules. The calls are in AppKit (NSWorkspace), so the UI
// of the chat gives the system version (SystemDefaultApps). A test gives a fake, so no test asks
// Launch Services.
package protocol DefaultApps: Sendable {
    // The facts of the app that opens the file (OpenerFacts): the app of the file itself, the
    // default app of its type, and the terminals (the apps that declare public.unix-executable).
    // The calls can wait for Launch Services.
    func opener(of file: FileFacts) -> OpenerFacts
}

// The lookups of Launch Services for the link rules. A lookup holds its thread until Launch
// Services answers, so it runs on the blocking executor, and at most one lookup runs at a time.
// A new link waits for the running lookup, then makes its own lookup. Its time limit includes
// the wait: a link that waits past its time limit makes no lookup.
package final class OpenerLookup: Sendable {
    private let apps: any DefaultApps
    // The task of the last lookup. The next lookup starts after its end, also when its link
    // stopped waiting.
    private let last = Mutex<Task<Void, Never>?>(nil)

    package init(apps: any DefaultApps) {
        self.apps = apps
    }

    // The answer of Launch Services, or nil when it gives no answer in the time limit
    // (LinkRules.openerTimeLimit on clock). A lookup that started continues after the time
    // limit, and the rules do not use its late answer.
    func opener(of file: FileFacts, clock: any Clock<Duration>) async -> OpenerFacts? {
        let (answers, answer) = AsyncStream.makeStream(of: OpenerFacts?.self)
        let apps = apps
        let lookup = last.withLock { last in
            let previous = last
            let next = Task {
                // The wait for the last lookup ignores a cancel, so two lookups never overlap.
                await previous?.value
                guard !Task.isCancelled else { return }
                answer.yield(await BlockingExecutor.run { apps.opener(of: file) })
            }
            last = next
            return next
        }
        let timer = Task {
            do {
                try await clock.sleep(for: LinkRules.openerTimeLimit)
            } catch {
                return
            }
            answer.yield(nil)
        }
        var first = answers.makeAsyncIterator()
        // A cancel of the caller ends the stream with no element. Then the result is nil too.
        let result = await first.next() ?? nil
        answer.finish()
        timer.cancel()
        // A lookup that waits for the last lookup does not start.
        lookup.cancel()
        return result
    }
}

extension LinkRules {
    // The action of the text of a link, from the facts of the file and the app that opens it.
    // Launch Services has a time limit (openerTimeLimit on clock): with no answer in that time,
    // Finder shows the file. The read of the file facts has no time limit. The reads can wait,
    // so this runs off the main actor.
    @concurrent package static func action(
        forLink link: String, localHost: String, lookup: OpenerLookup, clock: any Clock<Duration>
    ) async -> LinkAction {
        switch check(target(link, localHost: localHost), facts: FileFacts.init(atPath:)) {
        case .done(let action):
            return action
        case .askOpener(let file):
            return action(for: file, opener: await lookup.opener(of: file, clock: clock))
        }
    }
}
