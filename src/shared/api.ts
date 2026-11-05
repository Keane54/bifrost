import type { ClaudeVersion, InstallPreview, IntegrationStatus, SessionRow } from './types'

// The type of window.bifrost. The preload script implements it.
// When a call fails in the main process, it rejects with an Error.
// The message of that Error is the message of the failure.
export interface BifrostApi {
  claudePath(): Promise<string | null>
  claudeVersion(): Promise<ClaudeVersion>
  registry: {
    rows(): Promise<SessionRow[]>
    // Stop the flash of the box of the session.
    acknowledge(sessionId: string): Promise<void>
    // The main process sends a maximum of 4 updates each second.
    // The error is the error of the last poll of the session list, or null.
    // The returned function removes only this listener.
    onUpdate(cb: (rows: SessionRow[], error: string | null) => void): () => void
  }
  integration: {
    status(): Promise<IntegrationStatus>
    preview(): Promise<InstallPreview>
    // install and uninstall reject when the settings file is not valid.
    install(): Promise<IntegrationStatus>
    uninstall(): Promise<IntegrationStatus>
  }
  ui: {
    // The saved UI state, or null when the file is missing or damaged.
    load(): Promise<unknown>
    // Rejects when the value is not a plain object or is larger than 1 MB.
    save(data: unknown): Promise<void>
  }
  pty: {
    // The main process opens a PTY only for "attach <short id>".
    // The session must be owned and not parked.
    open(
      viewId: string,
      args: string[],
      opts: { cwd: string; cols: number; rows: number },
    ): Promise<number>
    write(viewId: string, data: string): Promise<boolean>
    resize(viewId: string, cols: number, rows: number): Promise<void>
    close(viewId: string, signal?: string): Promise<void>
    // Each on* function returns a function that removes only that listener.
    onData(cb: (viewId: string, chunk: string) => void): () => void
    onExit(cb: (viewId: string, exitCode: number, signal?: number) => void): () => void
  }
}
