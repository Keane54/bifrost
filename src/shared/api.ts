import type { AgentList } from '../main/claude/agents'
import type { ExecResult } from '../main/claude/cli'

// The type of window.bifrost. The preload script implements it.
export interface BifrostApi {
  claudePath(): Promise<string | null>
  agents: { list(all?: boolean): Promise<AgentList> }
  claude: { run(args: string[], cwd: string): Promise<ExecResult> }
  // The main process sends the signal only to a test session.
  proc: { signal(pid: number, signal: string): Promise<boolean> }
  pty: {
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
