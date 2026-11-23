# The look: behaviour

This page covers how Bifrost looks: its colours, the slowly moving background behind the canvas,
the blur behind overlapping frames, the UI font and the tooltips. The values are the ones the
user approved. The Electron app was a reference for behaviour only (user rule, 2026-11-16), and
the places where the native look differs from it on purpose are listed in
`docs/ports/look/DELIBERATE-DIFFERENCES.md`.

The code is in `BifrostLook`. `Model` holds the colour tokens, the motion of the background and
the tooltip rules, and `UI` holds the fonts, the blur, the Metal background, the tooltip and the
icons.

## Colours

The window is always dark, and a small set of colour tokens gives everything its colour:

| Token | Colour |
| --- | --- |
| Background | `#0a0a0a` |
| Panel edge | White at 10 % |
| Title bar | `#2a2a2a` |
| Text | `#d2d2d2` |
| Dim text | `#8a8a8a` |
| Strong text | White |
| Accent | Light cyan `#8fdcec` |
| Snap mark | `#bdbdbd` |

The accent is used sparingly: the top border of a frame, its glow and the tint of a press. The
background of a chat terminal is fully transparent, so the colour of the frame and its blur show
through, and the terminal's scroll slider is white at 40 % at rest, 60 % under the pointer and
80 % while it's dragged. Other tokens arrive with the panels that use them.

## The animated background

Behind the canvas, soft fields of colour drift slowly over a dark gradient, using the colours of
the app icon.

- The background has a base gradient, at an angle of 120 degrees and twice the size of the window
  in each direction, and six colour fields in the icon's colours. Yellow and orange come only from
  the fields, because a dark yellow or orange in the base looks brown.
- The base gradient's stops are green, blue, violet, red and violet (`Motion.baseColours`). The
  Take control loader of a chat window uses the same list, so it always has the colours of the
  background.
- The strengths are 0.15 for the glow of a field, 0.10 for the base and 0.0075 for the fine grain
  on top. Each field fades almost to nothing before its edge, so no edge ever shows.
- The motion moves 30 times a second on the CSS ease-in-out curve, and each cycle runs forwards
  and then back. One Metal shader draws all the layers, and a Mac with no Metal device shows the
  plain background colour instead.
- The background draws on a thread of its own, never on the main thread, so a busy Mac or a slow
  window server can't hold up typing. It draws at most 30 frames a second, one for each step of
  the motion, into a small set of buffers that the window shows in turn. If every buffer is still
  in use, it skips that frame instead of waiting. While the window is minimised or fully covered
  it draws nothing, and it catches up as soon as the window shows again.
- The fields move only when the Animated background setting is on, the window is active (focused
  and visible) and reduced motion is off. When the window becomes inactive, the fields pause where
  they are. Turning the setting off after the fields have moved also pauses them, so they don't
  jump. When the setting is off from the start, or reduced motion is on, the fields stay at the
  first step of each cycle.

## Blur and scale

When one frame covers another, the frame on top blurs what's behind it, so the lower frame shows
through softly.

- The blur is a gaussian blur of 8 layout units (user decision). A private Core Animation layer
  (`CABackdropLayer` with the `gaussianBlur` filter) does it, and only one file uses that private
  API. If a later macOS removes the private classes, a public `NSVisualEffectView` material takes
  over, though it gives no control over the radius.
- One layout unit is `interfaceScale / 100` points, and the Interface scale runs from 80 to 150 %.
  The rects in the stored layout keep their meaning at every scale. The sums multiply by the
  percent before they divide, so 880 points at 110 % gives exactly 800 units.

## Fonts

- The UI font is Geist Mono in the weights 400, 500 and 600, from the OTF files of the Geist Mono
  1.8.0 release, one file for each weight, with the licence (OFL). The files are in the app's
  resources, and only the Bifrost process registers them, so the user's own fonts don't change.
- A weight under 400 uses 400, and a weight over 600 uses 600.
- A character that Geist Mono doesn't have falls back to SF Mono, then Menlo, then the system
  fallback. If the registration fails, the UI font is SF Mono.

## Tooltips

All the tooltips share one timing, so moving along a row of buttons doesn't wait at each one.

- A tooltip opens once the pointer has rested on its view for 300 ms. While another tooltip is
  showing, or up to 400 ms after one closed, the next one opens at once. A tooltip closes at once.
- It sits 6 units from its view, above or to the right, centred on the view. It flips to the
  other side when there's no room, and slides along its side to stay 5 units inside the window,
  but it never leaves its view behind.

Some Electron pieces belonged to the web page and weren't carried over: the CSS files, the seven
canvases and their compositor transforms, the SVG grain and the font-face rules. The Metal shader
and CoreText do those jobs.
