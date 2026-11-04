import * as pty from 'node-pty'
import type { SpawnFn } from './pty-manager'

// Only this file imports node-pty. node-pty is built for Electron, so tests must not load it.
export const nodePtySpawn: SpawnFn = (file, args, opts) =>
  pty.spawn(file, args, {
    cols: opts.cols,
    cwd: opts.cwd,
    env: opts.env,
    name: 'xterm-256color',
    rows: opts.rows,
  })
