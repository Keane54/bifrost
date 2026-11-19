// The model of a claude run: the model of a new session, and the model of a review run in the
// settings. standard (the empty text) gives no --model flag, so claude uses its default model.
package enum ModelChoice: String, Sendable, CaseIterable, Codable {
    case standard = ""
    case opus, sonnet, haiku
}

extension ModelChoice {
    // The model choice of a model of a transcript or of a usage line, by its family: a model ID
    // such as claude-opus-5-5, or an alias such as opus[1m]. A model of another family gives nil.
    package init?(modelID: String) {
        let id = modelID.lowercased()
        let family = id.hasPrefix("claude-") ? id.dropFirst("claude-".count) : Substring(id)
        for choice in [ModelChoice.opus, .sonnet, .haiku] {
            let name = choice.rawValue
            if family == name || family.hasPrefix("\(name)-") || family.hasPrefix("\(name)[") {
                self = choice
                return
            }
        }
        return nil
    }
}
