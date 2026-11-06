// The gate for hold keys (D8). A hold key acts at the keyup, and only when no row click used it.
interface HeldKey {
  // True when the key went down in the other zone.
  active: boolean
  // True when a row click used the key.
  used: boolean
}

export class HoldGate {
  private readonly keys = new Map<string, HeldKey>()
  // The key that the last primary pointer-down on a row claimed, and the ID of that row.
  private claim: { key: string; target: string } | null = null

  // A key that is down already does nothing. This is the key repeat.
  down(key: string, active: boolean): void {
    if (this.keys.has(key)) return
    this.keys.set(key, { active, used: false })
  }

  // Remove the key. Give true only when the key was down, active and not used.
  up(key: string): boolean {
    const held = this.keys.get(key)
    this.keys.delete(key)
    return held?.active === true && !held.used
  }

  // Give the one active key that is down and mark it used. Else give null and mark nothing.
  click(): string | null {
    const active = [...this.keys].filter(([, held]) => held.active)
    if (active.length !== 1) return null
    const [key, held] = active[0]
    held.used = true
    return key
  }

  // A primary pointer-down on a row. Claim the one active key that is down for this row and mark
  // it used. So a keyup before the mouse-up does not act on the selected row (final review
  // Important 2). A pointer-down with no such key removes an old claim.
  press(target: string): string | null {
    const key = this.click()
    this.claim = key === null ? null : { key, target }
    return key
  }

  // The click of a row. Give the key that the pointer-down on this row claimed, then remove the
  // claim. A click with no claim for this row gives null.
  release(target: string): string | null {
    const claim = this.claim
    this.claim = null
    return claim !== null && claim.target === target ? claim.key : null
  }

  // True while exactly one active key is down. Then a row click is a hold click, also when the
  // click used the key.
  holding(): boolean {
    return [...this.keys.values()].filter(held => held.active).length === 1
  }

  // Forget all keys and the claim (window blur, a hidden page, the Cmd key, the key recorder).
  clear(): void {
    this.keys.clear()
    this.claim = null
  }

  isDown(key: string): boolean {
    return this.keys.has(key)
  }
}
