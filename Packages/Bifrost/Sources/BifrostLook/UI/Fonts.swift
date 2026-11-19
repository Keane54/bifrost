// The UI font of Bifrost: Geist Mono Regular, Medium and SemiBold. Resources/Fonts has the OTF
// file of each face from the Geist Mono 1.8.0 release, and its licence (OFL). When Geist Mono
// does not have a character, CoreText takes the fonts of the cascade list: SF Mono, then Menlo,
// then the fallback of the system.
import AppKit
import CoreText
import Synchronization

@MainActor
package enum Fonts {
    // One face of the font: the PostScript name and the AppKit weight. The file of the face has
    // the PostScript name.
    @MainActor
    private struct Face {
        var name: String
        var weight: NSFont.Weight
    }

    private static let faces = [
        Face(name: "GeistMono-Regular", weight: .regular),
        Face(name: "GeistMono-Medium", weight: .medium),
        Face(name: "GeistMono-SemiBold", weight: .semibold),
    ]

    // Only this process can use the fonts. The scopes .user and .persistent change the fonts of
    // the user.
    static let scope = CTFontManagerScope.process

    private static var registered = false

    // The fonts that ui() made, by face and size. ui() makes each font one time.
    @MainActor
    private struct FontKey: Hashable {
        var face: String
        var size: CGFloat
    }

    private static var madeFonts: [FontKey: NSFont] = [:]
    // The most fonts that the cache keeps. The app uses few sizes, so the limit is wide.
    private static let fontLimit = 64

    // A failure of the registration. The registration handler can run on another thread.
    @MainActor
    private final class Failure: Sendable {
        let found = Mutex(false)
    }

    // The folder of the font files in the resource bundle.
    static var folder: URL? { Bundle.module.url(forResource: "Fonts", withExtension: nil) }

    // Register the file of each weight for this process. True when the three faces can be used.
    // A later call gives the result again. A face that this process registered before is not an
    // error.
    package static func register() -> Bool {
        if registered { return true }
        guard let folder else { return false }
        let urls = faces.map { folder.appending(path: "\($0.name).otf") }
        let failure = Failure()
        CTFontManagerRegisterFontURLs(urls as CFArray, scope, true) { errors, _ in
            let list = errors as? [NSError] ?? []
            let real = list.contains {
                $0.code != CTFontManagerError.alreadyRegistered.rawValue
            }
            if real { failure.found.withLock { $0 = true } }
            return true
        }
        let found = faces.allSatisfy { NSFont(name: $0.name, size: 12) != nil }
        registered = !failure.found.withLock { $0 } && found
        return registered
    }

    // The face with the nearest weight. So a weight under regular takes the regular face, and a
    // weight over semibold takes the semibold face. Of two faces at the same distance, the
    // lighter face wins.
    private static func face(_ weight: NSFont.Weight) -> Face {
        let distance = { (face: Face) in abs(face.weight.rawValue - weight.rawValue) }
        return faces.min { distance($0) < distance($1) } ?? faces[0]
    }

    // Geist Mono at a size in points, with SF Mono and Menlo as the cascade list. The first call
    // registers the fonts. When the fonts cannot be registered, the result is SF Mono, the first
    // font of the cascade list.
    package static func ui(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let face = face(weight)
        let key = FontKey(face: face.name, size: size)
        if let made = madeFonts[key] { return made }
        guard register(), let font = NSFont(name: face.name, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: face.weight)
        }
        let cascade = [
            NSFont.monospacedSystemFont(ofSize: size, weight: face.weight).fontDescriptor,
            NSFontDescriptor(name: "Menlo-Regular", size: size),
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: cascade])
        let made = NSFont(descriptor: descriptor, size: size) ?? font
        if madeFonts.count >= fontLimit { madeFonts.removeAll() }
        madeFonts[key] = made
        return made
    }
}
