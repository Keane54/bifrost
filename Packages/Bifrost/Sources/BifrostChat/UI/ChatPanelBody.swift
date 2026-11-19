// The body of a chat panel. The canvas shows it in a frame. It holds:
// - the host: the terminal view of the chat at the top left. The sublayer transform of the host
//   zooms the terminal to fit the panel (docs/behaviour/chat.md, "The size"): never above 1, with
//   the top left corner in place.
// - the pointer blocker: a clear cover over a zoomed terminal of a window that is not focused.
//   A zoomed terminal gives wrong mouse cells, so the first click on such a window only focuses
//   it. The press still gets to the frame, which comes to the front.
// - the note: the reason why the window cannot attach, or the agent view limit.
// - the Take control loader (LoaderLayer) over the whole body. While it shows, the host and the
//   note are transparent: the terminal keeps its size and its focus, so the attach does not
//   change (docs/behaviour/chat.md, "The Take control loader").
// - the dictation notice at the top, above all other parts.
//
// The canvas keeps the body while the panel is in a frame. A new terminal of the session (for
// example after a close of the window and a reopen) uses the same body.
import AppKit
import BifrostDictation
import BifrostLook

package final class ChatPanelBody: NSView {
    // The parent of the terminal view. The view is flipped, so its layer is flipped too, and the
    // scale of the sublayer transform keeps the top left corner in place.
    final class Host: NSView {
        var scale = 1.0 {
            didSet { applyScale() }
        }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            applyScale()
        }

        private func applyScale() {
            let s = CGFloat(scale)
            layer?.sublayerTransform =
                s == 1 ? CATransform3DIdentity : CATransform3DMakeScale(s, s, 1)
        }
    }

    // Takes each press while it shows, so the terminal does not get it.
    final class PointerBlocker: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
    }

    let host = Host()
    let blocker = PointerBlocker()
    let note = NSView()
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let dictationNotice = DictationNoticeView()
    package let loader = LoaderLayer()
    // The terminal that uses the body now. It gets each change of the panel size.
    weak var owner: ChatTerminal?
    // The sizes of the note in layout units: the space between the edge of the panel and the
    // text, and the size of the text.
    static let noteInset = 16.0, noteTextSize = 13.0
    // The note inset in points at the Interface scale.
    private var noteInset: CGFloat = 16

    override package var isFlipped: Bool { true }

    init(metrics: CanvasMetrics) {
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        blocker.isHidden = true
        // The note: the background colour at 80 %, the dim text, in the middle.
        note.wantsLayer = true
        note.layer?.backgroundColor = ThemeTokens.bg.nsColor.withAlphaComponent(0.8).cgColor
        note.isHidden = true
        noteLabel.alignment = .center
        noteLabel.textColor = ThemeTokens.textDim.nsColor
        noteLabel.isSelectable = false
        note.addSubview(noteLabel)
        for view in [host, blocker, note, loader, dictationNotice] as [NSView] {
            addSubview(view)
        }
        setMetrics(metrics)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The size of the panel, or nil when no panel shows the terminal: the body is in no window
    // (a back tab, a minimised frame, a closed window) or it has no size.
    var panelSize: CGSize? {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds.size
    }

    // The zoom of the terminal (1: no zoom), and the pointer blocker.
    var scale: Double { host.scale }

    // The text of the note, or nil when the note does not show.
    var noteText: String? { note.isHidden ? nil : noteLabel.stringValue }

    func setMetrics(_ metrics: CanvasMetrics) {
        noteLabel.font = Fonts.ui(metrics.points(Self.noteTextSize), weight: .regular)
        noteInset = metrics.points(Self.noteInset)
        loader.setMetrics(metrics)
        dictationNotice.setMetrics(metrics)
        needsLayout = true
    }

    func setScale(_ scale: Double, blocksPointer: Bool) {
        host.scale = scale
        blocker.isHidden = !blocksPointer
    }

    // The notice line of the dictation, or nil.
    func showDictationNotice(_ line: NoticeLine?) {
        dictationNotice.show(line)
    }

    func showNote(_ text: String?) {
        noteLabel.stringValue = text ?? ""
        note.isHidden = text == nil
        needsLayout = true
    }

    // True while the Take control loader shows.
    package var showsLoader: Bool { !loader.isHidden }

    // Show the Take control loader with its line, or hide it (nil). While it shows, the terminal
    // and the note are transparent.
    func showLoader(_ text: String?, reduceMotion: Bool) {
        if let text {
            loader.show(text, reduceMotion: reduceMotion)
        } else {
            loader.hide()
        }
        let alpha: CGFloat = text == nil ? 1 : 0
        host.alphaValue = alpha
        note.alphaValue = alpha
        needsLayout = true
    }

    // A new terminal takes the body. The zoom, the blocker and the note of an older terminal go.
    func adopt(_ terminal: ChatTerminal) {
        owner = terminal
        for view in host.subviews { view.removeFromSuperview() }
        setScale(1, blocksPointer: false)
        showNote(nil)
        showDictationNotice(nil)
    }

    // The terminal of the body ended. The body shows nothing, as an empty panel of a chat that
    // has no terminal.
    func release(_ terminal: ChatTerminal) {
        guard owner === terminal else { return }
        owner = nil
        for view in host.subviews { view.removeFromSuperview() }
        setScale(1, blocksPointer: false)
        showNote(nil)
        showDictationNotice(nil)
        dictationNotice.openSettings = {}
    }

    // The terminal follows the size of the panel at once. The parts of the body follow it in the
    // layout pass.
    override package func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.panelChanged()
    }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.panelChanged()
    }

    override package func layout() {
        super.layout()
        for view in [host, blocker, note, loader, dictationNotice] as [NSView] {
            view.frame = bounds
        }
        let inset = bounds.insetBy(
            dx: min(noteInset, bounds.width / 2), dy: min(noteInset, bounds.height / 2))
        let height = min(inset.height, noteLabel.sizeThatFits(inset.size).height)
        noteLabel.frame = CGRect(
            x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height)
    }
}
