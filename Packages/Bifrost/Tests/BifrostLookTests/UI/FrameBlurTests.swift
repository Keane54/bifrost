import AppKit
import BifrostTestSupport
import QuartzCore
import Testing

@testable import BifrostLook

// The blur behind a frame (the section "The UI" of the architecture design): the private
// CABackdropLayer with a gaussian blur of 8 points (user decision), and the public
// NSVisualEffectView material when the private classes are not there.

// A lookup without the named classes, as a later macOS can be.
@MainActor
private func without(_ missing: Set<String>) -> PrivateClassLookup {
    PrivateClassLookup { missing.contains($0) ? nil : PrivateClassLookup.system.classNamed($0) }
}

// The radius of the gaussian filter of a backdrop blur.
@MainActor
private func radius(_ blur: any FrameBlur) -> Double? {
    guard let filter = blur.view.layer?.filters?.first as? NSObject else { return nil }
    return (filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue
}

@MainActor
@Suite("frame blur", .timeLimit(.minutes(1)), .tags(.window))
struct FrameBlurTests {
    init() { UITestApp.prepare() }

    @Test func backdropFallsBackToTheMaterialWithoutThePrivateClasses() {
        for missing in [["CABackdropLayer"], ["CAFilter"], ["CABackdropLayer", "CAFilter"]] {
            let blur = Blur.make(.backdrop, privateClasses: without(Set(missing)))
            #expect(blur?.kind == .material, "\(missing)")
            #expect(blur?.view is NSVisualEffectView, "\(missing)")
        }
        let none = PrivateClassLookup { _ in nil }
        #expect(Blur.make(.backdrop, privateClasses: none)?.kind == .material)
        #expect(Blur.make(.material)?.kind == .material)
        #expect(Blur.make(.none) == nil)
    }

    // On this macOS the private classes are there. If a macOS update removes them, the app
    // gives the material, and this test shows it.
    @Test func backdropUsesThePrivateLayerWhenItIsThere() {
        let blur = Blur.make(.backdrop)
        #expect(blur?.kind == .backdrop)
        #expect(blur.map { !($0.view is NSVisualEffectView) } == true)
    }

    @Test func theBlurRadiusIs8() throws {
        #expect(ThemeTokens.blurRadius == 8)
        let blur = try #require(Blur.make(.backdrop))
        #expect(radius(blur) == 8)
        // One layout unit is interfaceScale / 100 points, so the radius scales with the UI.
        blur.setScale(1.5)
        #expect(radius(blur) == 12)
        blur.setScale(0.8)
        #expect(radius(blur) == 6.4)
    }

    @Test func theMaterialIsTheDarkHUDMaterialInTheWindow() throws {
        let view = try #require(Blur.make(.material)?.view as? NSVisualEffectView)
        #expect(view.material == .hudWindow)
        #expect(view.blendingMode == .withinWindow)
        #expect(view.state == .active)
    }
}
