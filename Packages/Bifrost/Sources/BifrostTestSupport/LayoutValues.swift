import BifrostFoundation
import BifrostLayout
import Foundation

// Helpers of the tests of the window layout. The labels of rect(h:w:x:y:) and size are in the
// order h, w, x, y.

package func rect(h: Double, w: Double, x: Double, y: Double) -> LayoutRect {
    LayoutRect(x: x, y: y, w: w, h: h)
}

// A rect with the values in the order x, y, w, h (the tests of the canvas and the chats).
package func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutRect {
    LayoutRect(x: x, y: y, w: w, h: h)
}

package func size(h: Double, w: Double) -> LayoutSize {
    LayoutSize(w: w, h: h)
}

package func point(x: Double, y: Double) -> LayoutPoint {
    LayoutPoint(x: x, y: y)
}

// A panel ID that the test knows is good.
package func panel(_ raw: String) -> PanelID {
    guard let id = PanelID(raw) else { preconditionFailure("not a panel ID: \(raw)") }
    return id
}

// The frame ID f<number>.
package func frameID(_ number: Int) -> FrameID {
    FrameID(number: number)
}

// The value that a store reads from a file with this JSON value: the decode of the value, or the
// default when the decode refuses the value.
package func loaded<Value: Decodable>(_ value: JSONValue, else fallback: Value) -> Value {
    guard let data = try? JSONEncoder().encode(value) else { return fallback }
    return (try? JSONDecoder().decode(Value.self, from: data)) ?? fallback
}

// The JSON value that the encode of a value gives.
package func encoded(_ value: some Encodable) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
