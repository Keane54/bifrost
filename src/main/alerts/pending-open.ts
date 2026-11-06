// The session of a click on a notification (D13). When no page is loaded, for example after the
// window closed, the page cannot get alerts:open. So a click at that time keeps the session, and
// the next page that loads gets it, one time (final review Minor 6).
export class PendingOpen {
  private loaded = false
  private sessionId: string | null = null

  // A click on a notification. Give the session to send now, or null when it waits for a page.
  // A newer click replaces the session that waits.
  click(sessionId: string): string | null {
    if (this.loaded) return sessionId
    this.sessionId = sessionId
    return null
  }

  // A page starts to load, or the page ends (a closed window, a gone render process).
  unload(): void {
    this.loaded = false
  }

  // A page loaded. Give the session that waits, one time.
  load(): string | null {
    this.loaded = true
    const sessionId = this.sessionId
    this.sessionId = null
    return sessionId
  }
}
