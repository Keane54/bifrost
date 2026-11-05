// QuietWatch tells when the output of an attach was quiet for quietMs one time (spec 8.4).
// The first chunk starts the timer. Each chunk starts it again.
// After the timer fires, the watch stays settled and ignores more chunks.
export class QuietWatch {
  private timer: ReturnType<typeof setTimeout> | undefined
  private done = false
  private disposed = false
  private readonly waiters = new Set<(settled: boolean) => void>()

  constructor(private readonly quietMs: number) {}

  data(): void {
    if (this.done || this.disposed) return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.settle(), this.quietMs)
  }

  get settled(): boolean {
    return this.done
  }

  // Resolve true when the watch settles, or at once when it settled.
  // Resolve false at the timeout or when dispose runs.
  wait(timeoutMs: number): Promise<boolean> {
    if (this.done) return Promise.resolve(true)
    if (this.disposed) return Promise.resolve(false)
    return new Promise(resolve => {
      const finish = (settled: boolean): void => {
        clearTimeout(timeout)
        this.waiters.delete(finish)
        resolve(settled)
      }
      const timeout = setTimeout(() => finish(false), timeoutMs)
      this.waiters.add(finish)
    })
  }

  // Stop the timer and resolve each wait with false. A settled watch stays settled.
  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    clearTimeout(this.timer)
    this.timer = undefined
    for (const finish of [...this.waiters]) finish(false)
  }

  private settle(): void {
    this.timer = undefined
    this.done = true
    for (const finish of [...this.waiters]) finish(true)
  }
}
