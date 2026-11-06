// The HTTP server on a Unix socket. It receives the lines of the Live details mod.
//
// The mod sends each line as POST /v1/event. The server answers at once and then checks the line.
// The server never takes a socket that another program uses. It never deletes a file that is not
// a socket.

import { chmodSync, lstatSync, mkdirSync, rmSync } from 'node:fs'
import http from 'node:http'
import net from 'node:net'
import { dirname } from 'node:path'
import { type LiveEvent, parseLiveLine } from './live-event'

export const LIVE_PATH = '/v1/event'
export const LIVE_BODY_MAX = 65_536
export const REQUEST_TIMEOUT_MS = 5000
export const MAX_CONNECTIONS = 64
const CHECK_INTERVAL_MS = 1000
const PROBE_TIMEOUT_MS = 500

export interface LiveServerState {
  listening: boolean
  error?: string
}

export interface LiveServer {
  start(): Promise<LiveServerState>
  stop(): void
  state(): LiveServerState
}

export interface LiveServerOptions {
  socketPath: string
  onEvent(ev: LiveEvent): void
  now(): number
  requestTimeoutMs?: number
  checkIntervalMs?: number
}

type Probe = 'free' | 'stale' | { error: string }

// Check the path before listen. A socket that accepts a connection belongs to another program.
function probe(socketPath: string): Promise<Probe> {
  let stat: ReturnType<typeof lstatSync>
  try {
    stat = lstatSync(socketPath)
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return Promise.resolve('free')
    return Promise.resolve({ error: (err as Error).message })
  }
  if (!stat.isSocket()) {
    return Promise.resolve({
      error: `${socketPath} exists and is not a socket. Bifrost did not change it.`,
    })
  }
  return new Promise(resolve => {
    const socket = net.connect(socketPath)
    const finish = (result: Probe) => {
      socket.destroy()
      resolve(result)
    }
    socket.setTimeout(PROBE_TIMEOUT_MS, () =>
      finish({ error: `The socket ${socketPath} did not answer in ${PROBE_TIMEOUT_MS} ms.` }),
    )
    socket.once('connect', () => finish({ error: `Another program listens on ${socketPath}.` }))
    socket.once('error', (err: NodeJS.ErrnoException) =>
      finish(err.code === 'ECONNREFUSED' ? 'stale' : { error: err.message }),
    )
  })
}

export function createLiveServer(opts: LiveServerOptions): LiveServer {
  const { socketPath, onEvent, now } = opts
  const requestTimeout = opts.requestTimeoutMs ?? REQUEST_TIMEOUT_MS
  const checkInterval = opts.checkIntervalMs ?? CHECK_INTERVAL_MS
  let server: http.Server | null = null
  let owned = false
  let current: LiveServerState = { listening: false }
  let starting: Promise<LiveServerState> | null = null
  let startingGen = 0
  // A stop adds 1. A start that sees a new number must not listen.
  let generation = 0

  function handle(req: http.IncomingMessage, res: http.ServerResponse): void {
    if (req.method !== 'POST' || req.url !== LIVE_PATH) {
      res.writeHead(404, { Connection: 'close' }).end()
      req.resume()
      return
    }
    const chunks: Buffer[] = []
    let size = 0
    let refused = false
    req.on('data', (chunk: Buffer) => {
      if (refused) return
      size += chunk.length
      if (size > LIVE_BODY_MAX) {
        refused = true
        chunks.length = 0
        res.writeHead(413, { Connection: 'close' }).end(() => req.destroy())
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      if (refused) return
      res.writeHead(204).end()
      try {
        const ev = parseLiveLine(Buffer.concat(chunks).toString('utf8'), now())
        if (ev) onEvent(ev)
      } catch (err) {
        console.error('Live details: the handler of an event failed.', err)
      }
    })
    req.on('error', () => {})
  }

  const stopped = (): LiveServerState => {
    current = { listening: false }
    return current
  }

  function listen(gen: number): Promise<LiveServerState> {
    return new Promise(resolve => {
      const created = http.createServer(
        {
          connectionsCheckingInterval: checkInterval,
          headersTimeout: requestTimeout,
          requestTimeout,
        },
        handle,
      )
      created.maxConnections = MAX_CONNECTIONS
      created.on('clientError', (_err, socket) => socket.destroy())
      created.once('error', err => {
        created.close()
        current = { error: err.message, listening: false }
        resolve(current)
      })
      created.listen(socketPath, () => {
        if (gen !== generation) {
          created.close()
          created.closeAllConnections()
          rmSync(socketPath, { force: true })
          resolve({ listening: false })
          return
        }
        try {
          chmodSync(socketPath, 0o600)
        } catch (err) {
          created.close()
          current = { error: (err as Error).message, listening: false }
          resolve(current)
          return
        }
        server = created
        owned = true
        created.removeAllListeners('error')
        created.on('error', err => console.error('Live details: server error.', err))
        current = { listening: true }
        resolve(current)
      })
    })
  }

  async function run(gen: number): Promise<LiveServerState> {
    try {
      const dir = dirname(socketPath)
      mkdirSync(dir, { mode: 0o700, recursive: true })
      chmodSync(dir, 0o700)
      const found = await probe(socketPath)
      if (gen !== generation) return stopped()
      if (typeof found === 'object') {
        current = { error: found.error, listening: false }
        return current
      }
      if (found === 'stale') rmSync(socketPath, { force: true })
      return await listen(gen)
    } catch (err) {
      current = { error: (err as Error).message, listening: false }
      return current
    }
  }

  return {
    start() {
      if (server) return Promise.resolve(current)
      if (starting && startingGen === generation) return starting
      // A stop came while an old start ran. The new start waits for the old start to end.
      const gen = generation
      const previous = starting ?? Promise.resolve(current)
      const next: Promise<LiveServerState> = previous
        .then(() => run(gen))
        .finally(() => {
          if (starting === next) starting = null
        })
      starting = next
      startingGen = gen
      return next
    },
    state: () => current,
    stop() {
      generation += 1
      const closing = server
      server = null
      if (!closing) return
      closing.close()
      closing.closeAllConnections()
      if (owned) rmSync(socketPath, { force: true })
      owned = false
      current = { listening: false }
    },
  }
}
