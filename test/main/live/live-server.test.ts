import { type ChildProcess, spawn } from 'node:child_process'
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, test, vi } from 'vitest'
import type { LiveEvent } from '../../../src/main/live/live-event'
import { createLiveServer, type LiveServer } from '../../../src/main/live/live-server'

const S = '73b5ca76-a4a8-4f97-9764-e41657296414'
const good = JSON.stringify({
  at: 1000,
  kind: 'turn.complete',
  reason: 'answer',
  seq: 1,
  sid: S,
  v: 1,
})

const dirs: string[] = []
const servers: LiveServer[] = []
const others: net.Server[] = []

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'bl-'))
  dirs.push(dir)
  return dir
}

function setup(options: { requestTimeoutMs?: number; checkIntervalMs?: number } = {}) {
  const events: LiveEvent[] = []
  return { events, onEvent: (ev: LiveEvent) => events.push(ev), options }
}

async function make(
  dir: string,
  onEvent: (ev: LiveEvent) => void,
  options: { requestTimeoutMs?: number; checkIntervalMs?: number } = {},
) {
  const socketPath = join(dir, 'run', 'l.sock')
  const server = createLiveServer({ now: () => 1005, onEvent, socketPath, ...options })
  servers.push(server)
  return { server, socketPath }
}

function send(socketPath: string, method: string, path: string, body = ''): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = http.request({ method, path, socketPath }, res => {
      res.resume()
      res.on('end', () => resolve(res.statusCode ?? 0))
    })
    req.on('error', reject)
    req.end(body)
  })
}

afterEach(async () => {
  for (const server of servers.splice(0)) server.stop()
  for (const other of others.splice(0)) await new Promise(r => other.close(() => r(null)))
  for (const dir of dirs.splice(0)) await rm(dir, { force: true, recursive: true })
  vi.restoreAllMocks()
})

describe('createLiveServer', () => {
  test('start listens on the socket with mode 0600 in a directory with mode 0700', async () => {
    const { onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent)
    expect(await server.start()).toEqual({ listening: true })
    expect(statSync(socketPath).mode & 0o777).toBe(0o600)
    expect(statSync(join(socketPath, '..')).mode & 0o777).toBe(0o700)
    expect(await server.start()).toEqual({ listening: true })
    expect(server.state()).toEqual({ listening: true })
  })

  test('a POST of a good line gives 204 and one event', async () => {
    const { events, onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent)
    await server.start()
    expect(await send(socketPath, 'POST', '/v1/event', good)).toBe(204)
    await vi.waitFor(() => expect(events).toHaveLength(1))
    expect(events[0]).toMatchObject({ event: { name: 'Stop' }, type: 'state' })
  })

  test('a bad line gives 204 and no event', async () => {
    const { events, onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent)
    await server.start()
    expect(await send(socketPath, 'POST', '/v1/event', 'not json')).toBe(204)
    await new Promise(r => setTimeout(r, 50))
    expect(events).toHaveLength(0)
  })

  test('another path or method gives 404 and no event', async () => {
    const { events, onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent)
    await server.start()
    expect(await send(socketPath, 'GET', '/v1/event')).toBe(404)
    expect(await send(socketPath, 'POST', '/other', good)).toBe(404)
    await new Promise(r => setTimeout(r, 50))
    expect(events).toHaveLength(0)
  })

  test('a body over 65536 bytes gives 413 and no event', async () => {
    const { events, onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent)
    await server.start()
    expect(await send(socketPath, 'POST', '/v1/event', 'x'.repeat(70_000))).toBe(413)
    await new Promise(r => setTimeout(r, 50))
    expect(events).toHaveLength(0)
  })

  test('a request with no end is closed after the request timeout', async () => {
    const { events, onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent, {
      checkIntervalMs: 50,
      requestTimeoutMs: 200,
    })
    await server.start()
    const closed = new Promise<number>(resolve => {
      const started = Date.now()
      const socket = net.connect(socketPath, () => {
        socket.write('POST /v1/event HTTP/1.1\r\nHost: bifrost\r\nContent-Length: 500\r\n\r\n{"v":')
      })
      socket.on('error', () => {})
      socket.on('close', () => resolve(Date.now() - started))
    })
    expect(await closed).toBeLessThan(1000)
    expect(events).toHaveLength(0)
  })

  test('start replaces a stale socket file', async () => {
    const { onEvent } = setup()
    const dir = await tempDir()
    const { server, socketPath } = await make(dir, onEvent)
    const script = `
      const net = require('node:net')
      const fs = require('node:fs')
      fs.mkdirSync(require('node:path').dirname(${JSON.stringify(socketPath)}), { mode: 0o700, recursive: true })
      net.createServer().listen(${JSON.stringify(socketPath)}, () => {
        process.stdout.write('ready\\n')
        process.kill(process.pid, 'SIGKILL')
      })`
    const child: ChildProcess = spawn(process.execPath, ['-e', script], { stdio: 'ignore' })
    await new Promise(r => child.on('exit', r))
    expect(existsSync(socketPath)).toBe(true)
    expect(await server.start()).toEqual({ listening: true })
  })

  test('start does not take a socket that answers', async () => {
    const { onEvent } = setup()
    const dir = await tempDir()
    const { server, socketPath } = await make(dir, onEvent)
    const { mkdirSync } = await import('node:fs')
    mkdirSync(join(dir, 'run'), { mode: 0o700 })
    const other = net.createServer(s => s.end('hi'))
    others.push(other)
    await new Promise(r => other.listen(socketPath, () => r(null)))
    expect(await server.start()).toEqual({
      error: `Another program listens on ${socketPath}.`,
      listening: false,
    })
    server.stop()
    const answer = await new Promise<string>((resolve, reject) => {
      const c = net.connect(socketPath)
      c.on('data', d => resolve(String(d)))
      c.on('error', reject)
    })
    expect(answer).toBe('hi')
  })

  test('start never deletes a file that is not a socket', async () => {
    const { onEvent } = setup()
    const dir = await tempDir()
    const { server, socketPath } = await make(dir, onEvent)
    const { mkdirSync } = await import('node:fs')
    mkdirSync(join(dir, 'run'), { mode: 0o700 })
    writeFileSync(socketPath, 'keep me')
    expect(await server.start()).toEqual({
      error: `${socketPath} exists and is not a socket. Bifrost did not change it.`,
      listening: false,
    })
    server.stop()
    expect(readFileSync(socketPath, 'utf8')).toBe('keep me')
  })

  test('stop closes the server and removes the socket file', async () => {
    const { onEvent } = setup()
    const { server, socketPath } = await make(await tempDir(), onEvent)
    await server.start()
    const open = net.connect(socketPath)
    open.on('error', () => {})
    await new Promise(r => open.on('connect', () => r(null)))
    const closed = new Promise(r => open.on('close', () => r(null)))
    server.stop()
    expect(existsSync(socketPath)).toBe(false)
    expect(server.state().listening).toBe(false)
    await closed
    expect(() => server.stop()).not.toThrow()
  })

  test('a throw in onEvent does not stop the server', async () => {
    const dir = await tempDir()
    const seen: LiveEvent[] = []
    let first = true
    const { server, socketPath } = await make(dir, ev => {
      if (first) {
        first = false
        throw new Error('boom')
      }
      seen.push(ev)
    })
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    await server.start()
    expect(await send(socketPath, 'POST', '/v1/event', good)).toBe(204)
    expect(await send(socketPath, 'POST', '/v1/event', good)).toBe(204)
    await vi.waitFor(() => expect(seen).toHaveLength(1))
    expect(spy).toHaveBeenCalled()
  })
})
