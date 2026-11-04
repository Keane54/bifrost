// PageScope ties all PTYs to the page that the window shows now.
// A reload, a renderer crash, a window close or an app quit ends the page.
// When the page ends, PageScope closes all PTYs.
// A token identifies one page. An IPC handler gets a token before it waits.
// After the wait, the handler opens a PTY only if the token is still current.
export class PageScope {
  private value = 0

  constructor(private readonly closeAll: () => void) {}

  token(): number {
    return this.value
  }

  isCurrent(token: number): boolean {
    return token === this.value
  }

  end(): void {
    this.value += 1
    this.closeAll()
  }
}
