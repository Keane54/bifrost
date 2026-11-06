// The gate for hold keys (D8). A hold key acts at the keyup, and only when no row click used it.
interface HeldKey {
  // True when the key went down in the other zone.
  active: boolean
  // True when a row click used the key.
  used: boolean
}

export class HoldGate {
  private readonly keys = new Map<string, HeldKey>()

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

  // Forget all keys (window blur, a hidden page).
  clear(): void {
    this.keys.clear()
  }

  isDown(key: string): boolean {
    return this.keys.has(key)
  }
}
