import BifrostLook
import Foundation
import Testing

// The tests of the tokens that the native app has. The tokens are Swift constants that the user
// approved. The tests pin each value, and check the rules of the panel colours.

// The Swift token of each CSS name that the native app has.
private let tokens: [(css: String, token: TokenColour)] =
    [
        ("bg", ThemeTokens.bg), ("panel-edge", ThemeTokens.panelEdge), ("title", ThemeTokens.title),
        ("text", ThemeTokens.text), ("text-dim", ThemeTokens.textDim),
        ("text-strong", ThemeTokens.textStrong), ("accent", ThemeTokens.accent),
        ("accent-glow", ThemeTokens.accentGlow), ("snap", ThemeTokens.snap),
        ("terminal-bg", ThemeTokens.terminalBackground),
        ("terminal-slider", ThemeTokens.terminalSlider),
        ("terminal-slider-hover", ThemeTokens.terminalSliderHover),
        ("terminal-slider-active", ThemeTokens.terminalSliderActive),
        ("watch-green", ThemeTokens.watchGreen),
    ] + ThemeTokens.icons.enumerated().map { ("icon-\($0.offset + 1)", $0.element) }

// The value of a token: 8-bit channels and an alpha.
private func value(_ token: TokenColour) -> [Double] {
    let rgb = RGB(token)
    return [rgb.r, rgb.g, rgb.b, token.a]
}

// The approved value of each token: the channels and the alpha.
private let approved: [String: [Double]] = [
    "bg": [10, 10, 10, 1], "panel-edge": [255, 255, 255, 0.1], "title": [42, 42, 42, 1],
    "text": [210, 210, 210, 1], "text-dim": [138, 138, 138, 1],
    "text-strong": [255, 255, 255, 1], "accent": [143, 220, 236, 1],
    "accent-glow": [143, 220, 236, 0.28], "snap": [189, 189, 189, 1],
    "terminal-bg": [0, 0, 0, 0], "terminal-slider": [255, 255, 255, 0.4],
    "terminal-slider-hover": [255, 255, 255, 0.6], "terminal-slider-active": [255, 255, 255, 0.8],
    "watch-green": [34, 197, 94, 1], "icon-1": [232, 85, 78, 1], "icon-2": [240, 147, 63, 1],
    "icon-3": [240, 204, 88, 1], "icon-4": [116, 200, 142, 1], "icon-5": [94, 155, 236, 1],
    "icon-6": [155, 128, 230, 1],
]

// True when the token has the 8-bit channels of the CSS value: each channel is a whole number
// of 255 parts, so the Swift value gives the CSS text back.
private func isWhole(_ token: TokenColour) -> Bool {
    [token.r, token.g, token.b].allSatisfy {
        ($0 * 255 - ($0 * 255).rounded()).magnitude < 1e-9
    }
}

// The grey level of the panel colours: the red channel of a grey.
private func level(_ token: TokenColour) -> Double { RGB(token).r }

// The surfaces under the text of a chat terminal: the panel
// colour at each transparency, over each backdrop. The panel alphas come from ThemeTokens.
private func terminalSurfaces() -> [(String, RGB)] {
    let panel = RGB.grey(level(ThemeTokens.panel(transparency: 0)))
    let focus = RGB.grey(level(ThemeTokens.panelFocus(transparency: 0)))
    let icons = ThemeTokens.icons.map(RGB.init)
    let brightest = icons.dropFirst().reduce(icons[0]) { luminance($1) > luminance($0) ? $1 : $0 }
    let backdrops: [(String, RGB)] = [
        ("blurred text", mix(RGB(ThemeTokens.text), 0.25, panel)),
        (
            "a white watch row",
            mix(ReadableColours.watch[7].colour, ReadableColours.watchRowOpacity, panel)
        ),
        ("a selected row", mix(RGB(ThemeTokens.accent), 0.15, panel)),
        ("a loader band", mix(brightest, 0.25, panel)),
    ]
    var surfaces: [(String, RGB)] = []
    for (place, backdrop) in backdrops {
        for percent in ThemeTokens.transparencyChoices {
            let plain = mix(panel, ThemeTokens.panel(transparency: percent).a, backdrop)
            let top = mix(focus, ThemeTokens.panelFocus(transparency: percent).a, backdrop)
            surfaces.append(("on panel at \(percent)% over \(place)", plain))
            surfaces.append(("on focused panel at \(percent)% over \(place)", top))
        }
    }
    return surfaces
}

@Suite("theme")
struct ThemeTokensTests {
    @Test("each token has its approved value with whole 8-bit channels")
    func approvedValues() {
        #expect(Set(tokens.map(\.css)) == Set(approved.keys))
        for (name, token) in tokens {
            #expect(value(token) == approved[name], "\(name)")
            #expect(isWhole(token), "\(name)")
        }
        #expect(ThemeTokens.icons.count == 6)
        // An icon colour has its number, from 1 to 6. A number out of the range gets the
        // nearest colour.
        #expect((1...6).map(ThemeTokens.icon) == ThemeTokens.icons)
        #expect(ThemeTokens.icon(0) == ThemeTokens.icons[0])
        #expect(ThemeTokens.icon(7) == ThemeTokens.icons[5])
    }

    // The panel colours: the channels of the token and the alpha rule. The alpha of the panel is
    // 1 - transparency / 100, and the alpha of the focused panel is 0.1 more, at most 1. An
    // alpha from outside the choices stays between 0 and 1.
    @Test(
        "panel colours have their channels and alpha at each transparency",
        arguments: [-20] + ThemeTokens.transparencyChoices + [100, 120])
    func panelRule(percent: Int) {
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        let alpha = 1 - Double(percent) / 100
        let plain = ThemeTokens.panel(transparency: percent)
        let top = ThemeTokens.panelFocus(transparency: percent)
        #expect(Array(value(plain).prefix(3)) == [24, 24, 24])
        #expect(Array(value(top).prefix(3)) == [8, 8, 8])
        #expect(plain.a == clamp(alpha))
        #expect(top.a == clamp(alpha + 0.1))
    }

    @Test
    func defaultsOfThePanel() {
        #expect(ThemeTokens.panel(transparency: ThemeTokens.defaultTransparency).a == 0.85)
        #expect(ThemeTokens.blurRadius == 8)
    }

    @Test
    func accentAndGlow() {
        #expect(ThemeTokens.accent == TokenColour.rgb(0x8f, 0xdc, 0xec))
        #expect(ThemeTokens.accentGlow == TokenColour.rgb(143, 220, 236, alpha: 0.28))
    }

    @Test("a frame has one light backdrop blur of 6 to 8 px, only over a lower frame")
    func blurRadius() {
        #expect(ThemeTokens.blurRadius >= 6)
        #expect(ThemeTokens.blurRadius <= 8)
    }

    // The colours of the Overview have the values of the approved look, as hex colours with an
    // alpha: the project, tab and priority colours in their order, the boxes, the parked text,
    // the selection and the hover, the context bands, and the watch colours with their row
    // opacity of 12 %.
    @Test func theOverviewTokensMatchAppCss() {
        func hex(_ token: TokenColour) -> String {
            let rgb = RGB(token)
            return rgb.description + (token.a == 1 ? "" : String(format: "/%.2f", token.a))
        }
        #expect(
            ThemeTokens.projects.map(hex) == [
                "#93c5fd", "#60a5fa", "#2dd4bf", "#4ade80", "#34d399", "#7aa2d6", "#38bdf8",
                "#a3d63a",
            ])
        #expect(
            ThemeTokens.tabs.map(hex) == [
                "#7cc4d6", "#8fb8e8", "#86c48f", "#5fb3a1", "#6f9fe6", "#9fd0c0", "#e0443c",
                "#d4730a", "#fde68a", "#a3e635", "#f2f2f2", "#7dd3fc",
            ])
        #expect(
            ThemeTokens.priorities.map(hex) == [
                "#d4730a", "#93c5fd", "#5b9cf2", "#3fbfb0", "#7fc77a",
            ])
        let named: [(TokenColour, String)] = [
            (ThemeTokens.boxYellow, "#e2b93b"), (ThemeTokens.boxRed, "#f5766d"),
            (ThemeTokens.parked, "#6b7280"), (ThemeTokens.select, "#8fdcec/0.15"),
            (ThemeTokens.hover, "#ffffff/0.05"), (ThemeTokens.ctxLow, "#22c55e"),
            (ThemeTokens.ctxMid, "#d4730a"), (ThemeTokens.ctxHigh, "#dc2626"),
        ]
        for (token, value) in named { #expect(hex(token) == value) }
        let watch = [
            ThemeTokens.watchDarkRed, ThemeTokens.watchRed, ThemeTokens.watchAmber,
            ThemeTokens.watchYellow, ThemeTokens.watchGreen, ThemeTokens.watchLightBlue,
            ThemeTokens.watchDarkBlue, ThemeTokens.watchWhite,
        ]
        #expect(watch.map(RGB.init) == ReadableColours.watch.map(\.colour))
        #expect(ThemeTokens.watchRowOpacity == ReadableColours.watchRowOpacity)
        #expect(RGB(ThemeTokens.boxRed) == ReadableColours.boxRed)
        #expect(RGB(ThemeTokens.boxYellow) == ReadableColours.boxYellow)
        // The selection is the accent at 15 %.
        #expect(ThemeTokens.select == ThemeTokens.accent.opacity(0.15))
        let overview = ThemeTokens.projects + ThemeTokens.tabs + ThemeTokens.priorities + watch
        #expect((overview + named.map(\.0)).allSatisfy(isWhole))
    }

    // Bug 8: the focused panel must be darker than the others, not lighter.
    @Test
    func focusIsDarker() {
        let panel = ThemeTokens.panel(transparency: 15)
        #expect(panel == TokenColour.rgb(24, 24, 24, alpha: 0.85))
        #expect(level(ThemeTokens.panelFocus(transparency: 15)) < level(panel))
    }

    @Test
    func topFrameLessTransparent() {
        for percent in ThemeTokens.transparencyChoices {
            let alpha = ThemeTokens.panel(transparency: percent).a
            #expect(alpha == 1 - Double(percent) / 100)
            #expect(ThemeTokens.panelFocus(transparency: percent).a == min(1, alpha + 0.1))
            #expect(ThemeTokens.panelFocus(transparency: percent).a > alpha || alpha == 1)
        }
        #expect(ThemeTokens.panelFocus(transparency: 0).a == 1)
    }

    // The values of the Bifrost menu are the values of the table in docs/behaviour/menu.md, "The
    // look": the popup, a row and its fills, a separator, a submenu row, the check column, the
    // colour square, the gap below a button, the place of a tooltip and a field row.
    @Test func theMenuValuesMatchTheElectronClasses() {
        typealias M = ThemeTokens.Menu
        #expect(M.minWidth == 144)
        #expect(M.border == 1)
        #expect(M.paddingY == 4)
        #expect(M.textSize == 12)
        #expect(M.lineHeight == 16)
        #expect(M.rowHeight == 20)
        #expect(M.rowPaddingX == 8)
        #expect(M.rowGap == 8)
        #expect(value(M.highlight) == [255, 255, 255, 0.1])
        // The press tint and the open submenu row use the shared values.
        #expect(value(ThemeTokens.accent.opacity(0.12)) == [0x8f, 0xdc, 0xec, 0.12])
        #expect(value(ThemeTokens.hover) == [255, 255, 255, 0.05])
        #expect(M.disabledOpacity == 0.4)
        #expect(M.separatorHeight == 1)
        #expect(M.separatorMargin == 4)
        #expect(M.chevronSize == 12)
        #expect(M.submenuPaddingRight == 4)
        #expect(M.submenuRise == 5)
        #expect(M.checkColumn == 12)
        #expect(M.checkSize == 12)
        #expect(M.swatchSize == 8)
        #expect(M.belowGap == 4)
        #expect(TooltipPlacement.offset == 6)
        #expect(M.fieldGap == 4)
        #expect(M.fieldBoxPaddingX == 8)
        #expect(M.fieldBoxPaddingY == 4)
        #expect(value(M.fieldFocusBorder) == [255, 255, 255, 0.3])
        // A field box is a line of text with py-1 and a border: 26 high. Its row has the label
        // above it, gap-1 between, and 4 above and below: 54 high.
        #expect(M.fieldBoxHeight == 26)
        #expect(M.fieldRowHeight == 54)
    }
}

// User decision, 2026-11-06: the chat terminal has no black background. The frame colour and
// its blur show through, so the Panel transparency setting applies to chat windows too.
@Suite("the chat terminal background")
struct TerminalBackgroundTests {
    // The default text colour of xterm.js, and a mid grey as the dim text of Claude Code.
    private let text = RGB(255, 255, 255)
    private let dim = RGB(0x99, 0x99, 0x99)

    @Test("full transparency is fully transparent")
    func fullyTransparent() {
        #expect(ThemeTokens.terminalBackground == TokenColour(r: 0, g: 0, b: 0, a: 0))
    }

    @Test("panel text stays readable at each transparency over bright backdrops")
    func textReadable() {
        let surfaces = terminalSurfaces()
        var bad: [String] = []
        for (label, surface) in surfaces {
            if contrast(text, surface) < 7 { bad.append("text \(label)") }
            if contrast(dim, surface) < 4.5 { bad.append("dim text \(label)") }
        }
        #expect(surfaces.count == 4 * ThemeTokens.transparencyChoices.count * 2)
        #expect(bad == [])
    }
}

// User decision, 2026-11-09: the scroll bar of a chat window is clearly visible.
@Suite("the chat terminal scroll bar")
struct TerminalScrollBarTests {
    private static let sliders: [(String, TokenColour)] = [
        ("terminal-slider", ThemeTokens.terminalSlider),
        ("terminal-slider-hover", ThemeTokens.terminalSliderHover),
        ("terminal-slider-active", ThemeTokens.terminalSliderActive),
    ]

    @Test(arguments: ["terminal-slider", "terminal-slider-hover", "terminal-slider-active"])
    func hexWithAlpha(_ name: String) throws {
        let token = try #require(Self.sliders.first { $0.0 == name }?.1)
        // A hex alpha is a whole number of 255 parts.
        #expect((token.a * 255 - (token.a * 255).rounded()).magnitude < 1e-9)
        #expect(isWhole(token))
    }

    @Test
    func strongerOnHoverAndDrag() {
        let alphas = Self.sliders.map { $0.1.a }
        #expect(alphas[1] > alphas[0])
        #expect(alphas[2] > alphas[1])
    }

    // A part of the interface needs a contrast of 3:1 or more (WCAG 1.4.11).
    @Test(
        "the slider at rest stays visible at each transparency over bright backdrops")
    func sliderVisible() {
        let slider = ThemeTokens.terminalSlider
        let bad = terminalSurfaces()
            .map { ($0.0, contrast(mix(RGB(slider), slider.a, $0.1), $0.1)) }
            .filter { $0.1 < 3 }
            .map { "\($0.0): \(String(format: "%.2f", $0.1))" }
        #expect(bad == [])
    }
}
