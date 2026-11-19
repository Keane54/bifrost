import BifrostFoundation
import BifrostSettings
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

// The Interface scale in the saved settings.
private func scale(_ value: JSONValue) -> JSONValue? {
    guard case .object(let fields) = value else { return nil }
    return fields["interfaceScale"]
}

@MainActor
@Suite("the zoom items with the settings store", .timeLimit(.minutes(1)))
struct ZoomStepTests {
    // The zoom items of the menu change the Interface scale with an edit (MenuModel.zoomStep). A
    // step stays inside 80 to 150, so a step at a limit changes nothing and writes nothing.
    @Test func aZoomStepAtALimitChangesNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let counter = WriteCounter()
        let store = await SettingsStore.open(
            file: file, log: Recorder<StoreEvent>(), steps: counter.steps)
        func zoom(_ step: ZoomStep) async throws -> Int {
            try await store.edit {
                $0.interfaceScale = MenuModel.zoomStep($0.interfaceScale, step)
            }.interfaceScale
        }
        for _ in 0..<5 { _ = try await zoom(.zoomIn) }
        #expect(try await zoom(.zoomIn) == 150)
        #expect(counter.writes == 5)
        #expect(try await zoom(.reset) == 100)
        for _ in 0..<2 { _ = try await zoom(.zoomOut) }
        #expect(try await zoom(.zoomOut) == 80)
        #expect(counter.writes == 8)
        #expect(scale(try readSaved(file)) == 80)
    }
}
