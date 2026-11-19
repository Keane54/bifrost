// A coding key with any name: the keys of an object that a type does not name.
package struct DynamicKey: CodingKey, Sendable {
    package let stringValue: String

    package init(stringValue: String) {
        self.stringValue = stringValue
    }

    package var intValue: Int? { nil }

    package init?(intValue: Int) { nil }
}

// The error of a raw value or an unknown field that has no JSON value form, for example a number
// that Double cannot hold or a string with a lone surrogate. A save would lose that value, so a
// store treats the file as a file that does not parse and keeps a copy of it (FileSaver).
package struct NoJSONForm: Error, Equatable, Sendable {
    package init() {}
}

extension KeyedDecodingContainer {
    // The JSON value of a key that the container has, also null. A value with no JSON form throws
    // NoJSONForm, whatever error the decoder gives.
    package func jsonValue(forKey key: Key) throws(NoJSONForm) -> JSONValue {
        do {
            return try decode(JSONValue.self, forKey: key)
        } catch {
            throw NoJSONForm()
        }
    }
}

// The top-level fields of a stored object that its type does not know, for example the fields of
// a newer version of the app. Each stored type keeps them as a field. Its decode reads them with
// its known keys, and its encode writes them after its known keys, so a save of a file from a
// newer app loses nothing. A known key is never an unknown field, so a key of the value always
// wins.
package struct UnknownFields: Sendable, Equatable {
    package private(set) var values: [String: JSONValue]

    package init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    // The fields of the object of the decoder whose keys Known does not name. A value that has
    // no JSON form throws NoJSONForm.
    package init<Known: CodingKey>(from decoder: any Decoder, known _: Known.Type) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var values: [String: JSONValue] = [:]
        for key in container.allKeys where Known(stringValue: key.stringValue) == nil {
            values[key.stringValue] = try container.jsonValue(forKey: key)
        }
        self.values = values
    }

    // The fields of a parsed object whose keys are not in known. A type that parses a JSON value
    // (and not a decoder) keeps its unknown fields with this init.
    package init(_ object: [String: JSONValue], known: Set<String>) {
        self.values = object.filter { !known.contains($0.key) }
    }

    // The known fields with the unknown fields under them: a key of known always wins. A type
    // that makes a JSON value writes its unknown fields with this merge.
    package func merged(with known: [String: JSONValue]) -> [String: JSONValue] {
        known.merging(values) { knownValue, _ in knownValue }
    }

    // Write the fields into the object of the encoder, after its known keys.
    package func encode(to encoder: any Encoder) throws {
        guard !values.isEmpty else { return }
        var container = encoder.container(keyedBy: DynamicKey.self)
        // JSONFile writes the keys in sorted order, so the file does not depend on this order.
        for (key, value) in values {
            try container.encode(value, forKey: DynamicKey(stringValue: key))
        }
    }
}
