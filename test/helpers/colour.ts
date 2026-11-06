// The colour sums of the theme tests: the sRGB channels, the mix of two colours and the WCAG
// contrast. Each colour is a hex value with six digits.

export function rgb(hex: string): [number, number, number] {
  return [1, 3, 5].map(i => Number.parseInt(hex.slice(i, i + 2), 16)) as [number, number, number]
}

export function hex(channels: number[]): string {
  return `#${channels.map(c => Math.round(c).toString(16).padStart(2, '0')).join('')}`
}

// The colour over the background at the opacity.
export function mix(over: string, opacity: number, under: string): string {
  const a = rgb(over)
  const b = rgb(under)
  return hex(a.map((c, i) => c * opacity + b[i] * (1 - opacity)))
}

export function luminance(colour: string): number {
  const [r, g, b] = rgb(colour).map(c => {
    const v = c / 255
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}
