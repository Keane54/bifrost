import * as pty from 'node-pty'
import type { SpawnFn } from './pty-manager'

// Only this file imports node-pty. node-pty is built for Electron, so tests must not load it.
export const nodePtySpawn: SpawnFn = (file, args, opts) =>
  pty.spawn(file, args, {
    name: 'xterm-256color',
    cwd: opts.cwd,
    cols: opts.cols,
    rows: opts.rows,
    env: opts.env
  })
