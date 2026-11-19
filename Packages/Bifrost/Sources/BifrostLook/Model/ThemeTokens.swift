// The colour tokens of the look (docs/behaviour/look.md, "Colours"): the tokens that the window,
// the frames, the background, the tooltips, the chat terminal and the Overview use. The values
// are the values that the user approved. The other tokens come with the panels that use them.

// A colour with red, green, blue and alpha from 0 to 1, in sRGB.
package struct TokenColour: Sendable, Equatable {
    package var r, g, b, a: Double

    package init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    // A colour of 8-bit channels (0 to 255) and an alpha from 0 to 1.
    package static func rgb(_ r: Int, _ g: Int, _ b: Int, alpha: Double = 1) -> TokenColour {
        TokenColour(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: alpha)
    }

    // The same channels with another alpha, for a tint of a token: a watched row has its watch
    // colour at 12 %.
    package func opacity(_ alpha: Double) -> TokenColour {
        TokenColour(r: r, g: g, b: b, a: alpha)
    }
}

package enum ThemeTokens {
    package static let bg = TokenColour.rgb(0x0a, 0x0a, 0x0a)
    package static let panelEdge = TokenColour.rgb(255, 255, 255, alpha: 0.1)
    package static let title = TokenColour.rgb(0x2a, 0x2a, 0x2a)
    package static let text = TokenColour.rgb(0xd2, 0xd2, 0xd2)
    package static let textDim = TokenColour.rgb(0x8a, 0x8a, 0x8a)
    package static let textStrong = TokenColour.rgb(0xff, 0xff, 0xff)
    // The light cyan accent, used sparingly: the top border of each frame, its glow and the
    // tint of a press.
    package static let accent = TokenColour.rgb(0x8f, 0xdc, 0xec)
    package static let accentGlow = TokenColour.rgb(143, 220, 236, alpha: 0.28)
    package static let snap = TokenColour.rgb(0xbd, 0xbd, 0xbd)
    // The background of a chat terminal: fully transparent, so the frame colour and its blur
    // show through.
    package static let terminalBackground = TokenColour.rgb(0, 0, 0, alpha: 0)
    // The slider of the chat terminal scroll bar: at rest, under the pointer and during a drag.
    // The alphas are the byte alphas 0x66, 0x99 and 0xcc of white (40, 60 and 80 %).
    package static let terminalSlider = TokenColour.rgb(255, 255, 255, alpha: 0x66 / 255)
    package static let terminalSliderHover = TokenColour.rgb(255, 255, 255, alpha: 0x99 / 255)
    package static let terminalSliderActive = TokenColour.rgb(255, 255, 255, alpha: 0xcc / 255)
    // The green of the look of a chat window while it dictates (the green of the approved mock):
    // the top line, the glow and the mic with the level bar.
    package static let watchGreen = TokenColour.rgb(0x22, 0xc5, 0x5e)

    // The six colours of the app icon, icon-1 to icon-6. The background fields and the base use
    // them.
    package static let icons: [TokenColour] = [
        .rgb(0xe8, 0x55, 0x4e), .rgb(0xf0, 0x93, 0x3f), .rgb(0xf0, 0xcc, 0x58),
        .rgb(0x74, 0xc8, 0x8e), .rgb(0x5e, 0x9b, 0xec), .rgb(0x9b, 0x80, 0xe6),
    ]

    // MARK: - The Overview

    // The colours of the projects, project-1 to project-8: the glyph of a row icon. No colour is
    // yellow, red, orange or grey, so a project colour is not a box colour or the parked colour.
    package static let projects: [TokenColour] = [
        .rgb(0x93, 0xc5, 0xfd), .rgb(0x60, 0xa5, 0xfa), .rgb(0x2d, 0xd4, 0xbf),
        .rgb(0x4a, 0xde, 0x80), .rgb(0x34, 0xd3, 0x99), .rgb(0x7a, 0xa2, 0xd6),
        .rgb(0x38, 0xbd, 0xf8), .rgb(0xa3, 0xd6, 0x3a),
    ]
    // The colours of the Overview tabs, tab-1 to tab-12. The index of a colour is the colour of
    // a tab (OverviewTab.colour).
    package static let tabs: [TokenColour] = [
        .rgb(0x7c, 0xc4, 0xd6), .rgb(0x8f, 0xb8, 0xe8), .rgb(0x86, 0xc4, 0x8f),
        .rgb(0x5f, 0xb3, 0xa1), .rgb(0x6f, 0x9f, 0xe6), .rgb(0x9f, 0xd0, 0xc0),
        .rgb(0xe0, 0x44, 0x3c), .rgb(0xd4, 0x73, 0x0a), .rgb(0xfd, 0xe6, 0x8a),
        .rgb(0xa3, 0xe6, 0x35), .rgb(0xf2, 0xf2, 0xf2), .rgb(0x7d, 0xd3, 0xfc),
    ]
    // The colours of the priorities 1 to 5, prio-1 to prio-5.
    package static let priorities: [TokenColour] = [
        .rgb(0xd4, 0x73, 0x0a), .rgb(0x93, 0xc5, 0xfd), .rgb(0x5b, 0x9c, 0xf2),
        .rgb(0x3f, 0xbf, 0xb0), .rgb(0x7f, 0xc7, 0x7a),
    ]
    // The yellow box and the red box of a row, and the text of their state labels.
    package static let boxYellow = TokenColour.rgb(0xe2, 0xb9, 0x3b)
    package static let boxRed = TokenColour.rgb(0xf5, 0x76, 0x6d)
    // The text and the glyph of a parked row.
    package static let parked = TokenColour.rgb(0x6b, 0x72, 0x80)
    // The selected row: the accent at 15 %.
    package static let select = TokenColour.rgb(0x8f, 0xdc, 0xec, alpha: 0.15)
    // A hovered row and a row with an open chat.
    package static let hover = TokenColour.rgb(255, 255, 255, alpha: 0.05)
    // The bands of a context bar: below 40 %, from 40 %, and from 70 %. Each band is clear of the
    // box colours.
    package static let ctxLow = TokenColour.rgb(0x22, 0xc5, 0x5e)
    package static let ctxMid = TokenColour.rgb(0xd4, 0x73, 0x0a)
    package static let ctxHigh = TokenColour.rgb(0xdc, 0x26, 0x26)

    // The colours of a watched session, in the order of the colour picker. watchGreen (above) is
    // the green. A watched row has its colour at watchRowOpacity, and a stripe of the full colour
    // at its left edge.
    package static let watchDarkRed = TokenColour.rgb(0x7f, 0x1d, 0x1d)
    package static let watchRed = TokenColour.rgb(0xdc, 0x26, 0x26)
    package static let watchAmber = TokenColour.rgb(0xd4, 0x73, 0x0a)
    package static let watchYellow = TokenColour.rgb(0xfe, 0xf0, 0x8a)
    package static let watchLightBlue = TokenColour.rgb(0x7d, 0xd3, 0xfc)
    package static let watchDarkBlue = TokenColour.rgb(0x25, 0x63, 0xeb)
    package static let watchWhite = TokenColour.rgb(0xf2, 0xf2, 0xf2)
    package static let watchRowOpacity = 0.12

    // The colour of a project colour, 1 to 8 (the project colour index of a row icon).
    package static func project(_ number: Int) -> TokenColour {
        projects[min(max(number, 1), projects.count) - 1]
    }

    // The colour of a tab colour, 0 to 11 (the colour of an Overview tab).
    package static func tab(_ index: Int) -> TokenColour {
        tabs[min(max(index, 0), tabs.count - 1)]
    }

    // The colour of a priority, 1 to 5.
    package static func priority(_ number: Int) -> TokenColour {
        priorities[min(max(number, 1), priorities.count) - 1]
    }

    // The choices of the Panel transparency setting in percent, and its default. The settings
    // check the setting with them.
    package static let transparencyChoices = Array(stride(from: 0, through: 50, by: 5))
    package static let defaultTransparency = 15

    // The panel alpha of a Panel transparency setting in percent. Only the background of a panel
    // is translucent. Text and content stay solid.
    private static func panelAlpha(_ transparency: Int) -> Double {
        1 - Double(transparency) / 100
    }

    // An alpha stays from 0 to 1.
    private static func clamped(_ alpha: Double) -> Double { min(1, max(0, alpha)) }

    // The fill of a frame: the grey 24, 24, 24 at the panel alpha.
    package static func panel(transparency: Int) -> TokenColour {
        .rgb(24, 24, 24, alpha: clamped(panelAlpha(transparency)))
    }

    // The fill of the top frame: darker and less transparent than the other frames, the grey
    // 8, 8, 8 at the panel alpha plus 0.1.
    package static func panelFocus(transparency: Int) -> TokenColour {
        .rgb(8, 8, 8, alpha: clamped(panelAlpha(transparency) + 0.1))
    }

    // The radius of the blur behind a frame that covers a lower frame, in points at an interface
    // scale of 100.
    package static let blurRadius = 8.0

    // MARK: - The Usage HUD

    // The bar of a usage limit: teal up to 70 %, amber above 70 % (raised), and red from 90 %
    // (high). The HUD uses red at 90 % (user decision, 2026-11-18). The red is the strong red of
    // the watch states (watchRed): it stays clearly apart from the amber on the dark panel,
    // where the lighter boxRed looks close to a salmon pink.
    package static let usage = TokenColour.rgb(0x5f, 0xb3, 0xc9)
    package static let usageRaised = TokenColour.rgb(0xd4, 0x73, 0x0a)
    package static let usageHigh = watchRed
}

// MARK: - The Bifrost menu

extension ThemeTokens {
    // The look of the Bifrost menu (docs/behaviour/menu.md, "The look"). The sizes are in layout
    // units. A disabled row shows its reason in a tooltip of the look of the tooltips
    // (TooltipController), at its right side (TooltipPlacement.offset away).
    package enum Menu {
        // The popup: the title colour as fill, a border of the panel edge colour, a space above
        // and below the rows, and the UI font in the text colour. No shadow.
        package static let minWidth = 144.0
        package static let border = 1.0
        package static let paddingY = 4.0
        package static let textSize = 12.0
        // The height of a line of text: the label of a field row and the text in its box.
        package static let lineHeight = 16.0

        // A row: its height, the space at its sides and the space between its parts.
        package static let rowHeight = 20.0
        package static let rowPaddingX = 8.0
        package static let rowGap = 8.0
        // The fill of the highlighted row. A pressed row that is not disabled has the tint of a
        // press (the accent at 12 %), and the row of an open submenu has the hover fill while the
        // highlight is inside the submenu.
        package static let highlight = TokenColour.rgb(255, 255, 255, alpha: 0.1)
        // The opacity of a disabled row.
        package static let disabledOpacity = 0.4

        // A separator: a line of the panel edge colour, with a space above and below it.
        package static let separatorHeight = 1.0
        package static let separatorMargin = 4.0

        // A submenu row has the arrow at its right end and a smaller space at its right. The
        // submenu opens at the right of the row, this much higher than the row, so its first
        // row is level with the row.
        package static let chevronSize = 12.0
        package static let submenuPaddingRight = 4.0
        package static let submenuRise = 5.0

        // A check box or a radio row has a column for the check mark. A colour square is a
        // square of the colour of its token.
        package static let checkColumn = 12.0
        package static let checkSize = 12.0
        package static let swatchSize = 8.0

        // A menu below a button opens this far under the button.
        package static let belowGap = 4.0

        // A field row: the label above a box of the background colour with a border. The border
        // of the box is lighter while the box has the focus.
        package static let fieldPaddingX = 8.0
        package static let fieldPaddingY = 4.0
        package static let fieldGap = 4.0
        package static let fieldBoxPaddingX = 8.0
        package static let fieldBoxPaddingY = 4.0
        package static let fieldFocusBorder = TokenColour.rgb(255, 255, 255, alpha: 0.3)

        // The height of the box of a field row: the border, the space and one line of text.
        package static var fieldBoxHeight: Double { 2 * border + 2 * fieldBoxPaddingY + lineHeight }

        // The height of a field row.
        package static var fieldRowHeight: Double {
            2 * fieldPaddingY + lineHeight + fieldGap + fieldBoxHeight
        }
    }
}
