// The result of a run: every check in order, as one JSON object for CI and as lines for the
// alert.
struct Report {
    let checks: [Check]

    var passed: Bool { checks.allSatisfy(\.passed) }

    // {"checks":[{"name":"...","result":"PASS" or "FAIL","value":...}]} on one line.
    var json: String {
        let entries = checks.map { check -> JSON in
            [
                "name": .string(check.name), "result": .string(check.passed ? "PASS" : "FAIL"),
                "value": check.value,
            ]
        }
        let report: JSON = ["checks": .array(entries)]
        return String(decoding: report.encodedLine(), as: UTF8.self)
    }

    // A line for each check. A long value is cut short here, and the copied report has it whole.
    var lines: [String] {
        checks.map { check in
            let value = String(decoding: check.value.encodedLine(), as: UTF8.self)
            let line = "\(check.passed ? "PASS" : "FAIL")  \(check.name)  \(value)"
            return line.count > 240 ? line.prefix(240) + "…" : line
        }
    }
}
