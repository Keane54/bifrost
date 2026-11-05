// QuietWatch tells when the output of an attach was quiet for quietMs one time (spec 8.4).
// The first chunk starts the timer. Each chunk starts it again.
// After the timer fires, the watch stays settled and ignores more chunks.
// The watch also tells when the first chunk came. Then the attach is connected.
export class QuietWatch {
  private timer: ReturnType<typeof setTimeout> | undefined
  private done = false
  private seen = false
  private disposed = false
  private readonly settleWaiters = new Set<(ok: boolean) => void>()
  private readonly outputWaiters = new Set<(ok: boolean) => void>()

  constructor(private readonly quietMs: number) {}

  data(): void {
    if (this.disposed) return
    if (!this.seen) {
      this.seen = true
      for (const finish of [...this.outputWaiters]) finish(true)
    }
    if (this.done) return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.settle(), this.quietMs)
  }

  get settled(): boolean {
    return this.done
  }

  // True after the first chunk.
  get output(): boolean {
    return this.seen
  }

  // Resolve true when the watch settles, or at once when it settled.
  // Resolve false at the timeout or when dispose runs.
  wait(timeoutMs: number): Promise<boolean> {
    return this.waitFor(this.done, this.settleWaiters, timeoutMs)
  }

  // Resolve true at the first chunk, or at once after it.
  // Resolve false at the timeout or when dispose runs.
  waitOutput(timeoutMs: number): Promise<boolean> {
    return this.waitFor(this.seen, this.outputWaiters, timeoutMs)
  }

  // Stop the timer and resolve each wait with false. A settled watch stays settled.
  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    clearTimeout(this.timer)
    this.timer = undefined
    for (const finish of [...this.settleWaiters, ...this.outputWaiters]) finish(false)
  }

  private waitFor(
    already: boolean,
    waiters: Set<(ok: boolean) => void>,
    timeoutMs: number,
  ): Promise<boolean> {
    if (already) return Promise.resolve(true)
    if (this.disposed) return Promise.resolve(false)
    return new Promise(resolve => {
      const finish = (ok: boolean): void => {
        clearTimeout(timeout)
        waiters.delete(finish)
        resolve(ok)
      }
      const timeout = setTimeout(() => finish(false), timeoutMs)
      waiters.add(finish)
    })
  }

  private settle(): void {
    this.timer = undefined
    this.done = true
    for (const finish of [...this.settleWaiters]) finish(true)
  }
}
