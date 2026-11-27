import Foundation
import Testing

@testable import BifrostModuleHostCore

// The profile the module host gives sandbox_init. The host can't run under the package tests,
// because sandbox_init fails inside the test sandbox, so these read the profile's rules instead
// and the check app proves them on a real host.

// The operations of every allow rule, with the comments taken out. In SBPL the operations come
// straight after "allow" and before the first filter, so "(allow file-read* (literal "/x"))"
// gives file-read*.
private var allowedOperations: [String] {
    let code = SandboxProfile.text.split(separator: "\n").map { line in line.prefix { $0 != ";" } }
        .joined(separator: "\n")
    return code.components(separatedBy: "(allow").dropFirst().flatMap { rule in
        rule.prefix { $0 != "(" && $0 != ")" }.split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

@Suite("Sandbox profile")
struct SandboxProfileTests {
    // The list of operations can't be empty either, or the two tests below would pass on a
    // profile the parse got wrong.
    @Test func theProfileDeniesByDefault() {
        #expect(SandboxProfile.text.contains("(version 1)"))
        #expect(SandboxProfile.text.contains("(deny default)"))
        #expect(!allowedOperations.isEmpty)
        #expect(!allowedOperations.contains("default"))
    }

    // A socket of any kind counts as network, as well as the network operations themselves.
    @Test func theProfileAllowsNoNetwork() {
        #expect(!allowedOperations.contains { $0.hasPrefix("network") || $0 == "system-socket" })
    }

    @Test func theProfileAllowsNoProcessStart() {
        #expect(
            !allowedOperations.contains {
                $0.hasPrefix("process-exec") || $0.hasPrefix("process-fork") || $0 == "process*"
            })
    }
}
