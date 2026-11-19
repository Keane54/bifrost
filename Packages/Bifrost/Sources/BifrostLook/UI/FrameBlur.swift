// The blur behind a frame that covers a lower frame (docs/behaviour/look.md, "Blur and scale"). The
// rest of the app knows only the FrameBlur protocol and BlurKind. The private API is only in
// PrivateBackdrop.swift.
//
// - backdrop: the private CABackdropLayer with the private CAFilter "gaussianBlur" at 8 points
//   (user decision): the soft look that the user approved.
// - material: the public NSVisualEffectView (.hudWindow, within the window). It has no radius
//   control, and the lower frame does not show through as clearly.
// - none: no blur.
// If the private classes are not there (for example after a macOS update), make() gives the
// material in place of the backdrop.
import AppKit

nonisolated public enum BlurKind: String, Sendable, CaseIterable {
    case backdrop, material, none
}

// One blur view behind one frame. The frame puts `view` under its fill and sets its frame.
@MainActor
package protocol FrameBlur: AnyObject {
    var kind: BlurKind { get }
    var view: NSView { get }
    // The points of one layout unit (CanvasMetrics.scale). The radius of the blur is
    // ThemeTokens.blurRadius layout units.
    func setScale(_ scale: Double)
}

// The lookup of a class by its name. The tests give a lookup without the private classes.
nonisolated package struct PrivateClassLookup: Sendable {
    package var classNamed: @Sendable (String) -> AnyClass?

    package init(classNamed: @escaping @Sendable (String) -> AnyClass?) {
        self.classNamed = classNamed
    }
}

@MainActor
package enum Blur {
    // Make a blur of the kind, or nil for .none. The result can be of another kind when the
    // private API is not there. Read `kind` of the result.
    package static func make(
        _ kind: BlurKind, privateClasses: PrivateClassLookup = .system
    ) -> (any FrameBlur)? {
        switch kind {
        case .none: nil
        case .material: MaterialBlur()
        case .backdrop: PrivateBackdropBlur(classes: privateClasses) ?? MaterialBlur()
        }
    }
}

// The public form: NSVisualEffectView.
@MainActor
final class MaterialBlur: FrameBlur {
    let kind = BlurKind.material
    let view: NSView

    init() {
        let material = NSVisualEffectView()
        material.blendingMode = .withinWindow
        material.material = .hudWindow
        material.state = .active
        view = material
    }

    // The material has no radius.
    func setScale(_ scale: Double) {}
}
