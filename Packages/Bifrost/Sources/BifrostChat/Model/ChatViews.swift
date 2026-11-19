import BifrostFoundation
import BifrostLayout

// Which chat windows are open, visible and focused. The attach target of a window is
// AttachRules.target (AttachRules.swift).

// The view of a chat window. visible: the window shows the chat (the frame is not minimised and
// the chat is its active tab). focused: the chat is visible in the frame that has the focus (the
// top frame, until a click on the background of the canvas).
package struct ChatView: Sendable, Equatable {
    package var visible: Bool
    package var focused: Bool

    package init(visible: Bool, focused: Bool) {
        self.visible = visible
        self.focused = focused
    }

    // The view of a chat that no panel shows.
    package static let hidden = ChatView(visible: false, focused: false)
}

package enum ChatViews {
    // The session IDs of all chat panels, also in back tabs and in minimised frames. Each ID is
    // in the list one time, in the order of the frames and of their tabs.
    package static func openChatIds(_ frames: [LayoutFrame]) -> [SessionID] {
        var ids: [SessionID] = []
        for frame in frames {
            for panel in frame.panels {
                if case .chat(let id) = panel, !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    // The view of each chat panel of the layout, by session ID.
    package static func views(_ layout: WindowLayout) -> [String: ChatView] {
        let focused = layout.focusedFrame?.id
        var views: [String: ChatView] = [:]
        for frame in layout.frames {
            for panel in frame.panels {
                guard case .chat(let session) = panel else { continue }
                let visible = !frame.minimised && frame.active == panel
                views[session.text] = ChatView(
                    visible: visible, focused: visible && frame.id == focused)
            }
        }
        return views
    }

    // The session IDs that are focused in after and were not focused in before.
    package static func gainedFocus(_ before: [String: ChatView], _ after: [String: ChatView])
        -> Set<String>
    {
        let focused = after.filter { $0.value.focused }.keys
        return Set(focused.filter { before[$0]?.focused != true })
    }
}
