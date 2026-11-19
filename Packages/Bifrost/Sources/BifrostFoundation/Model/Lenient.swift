// A value that decodes to nil when it has the wrong type. One bad value then does not make
// the whole array or object fail. The parsers of the stores, the settings, the session list and
// the Live details lines use it.
package struct Lenient<Value: Decodable>: Decodable {
    package let decoded: Value?

    package init(from decoder: any Decoder) throws {
        decoded = try? Value(from: decoder)
    }
}
