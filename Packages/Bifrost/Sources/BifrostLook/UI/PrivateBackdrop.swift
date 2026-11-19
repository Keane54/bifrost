// The private form of the frame blur: CABackdropLayer with the CAFilter "gaussianBlur". This is
// the only file of the app that uses private API (forbidden rule private-api). The rest of the
// app knows only FrameBlur and BlurKind (FrameBlur.swift).
import AppKit
import QuartzCore

@MainActor
extension PrivateClassLookup {
    // The classes of the system, by name.
    nonisolated package static let system = PrivateClassLookup { NSClassFromString($0) }
}

@MainActor
final class PrivateBackdropBlur: FrameBlur {
    let kind = BlurKind.backdrop
    let view: NSView
    private let filter: NSObject

    // Nil when the private classes or the filter are not there.
    init?(classes: PrivateClassLookup) {
        guard let layerClass = classes.classNamed("CABackdropLayer") as? CALayer.Type,
            let filterClass = classes.classNamed("CAFilter") as? NSObject.Type,
            filterClass.responds(to: NSSelectorFromString("filterWithType:")),
            let made = filterClass.perform(
                NSSelectorFromString("filterWithType:"), with: "gaussianBlur"),
            let filter = made.takeUnretainedValue() as? NSObject
        else { return nil }
        // The edge setting stops a dark band at the edges.
        filter.setValue(true, forKey: "inputNormalizeEdges")
        self.filter = filter
        let backdrop = layerClass.init()
        let host = NSView()
        host.layer = backdrop
        host.wantsLayer = true
        view = host
        setScale(1)
    }

    func setScale(_ scale: Double) {
        filter.setValue(ThemeTokens.blurRadius * scale, forKey: "inputRadius")
        // A layer copies its filters, so the new value needs a new assignment.
        view.layer?.filters = [filter]
    }
}
