// This script runs after "pnpm install".
// It makes the Electron binary, rebuilds native modules and fixes node-pty.
import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

function run(command, args) {
  execFileSync(command, args, { stdio: 'inherit' })
}

// Step 1: download the Electron binary. The command does nothing if the binary exists.
run('pnpm', ['exec', 'install-electron'])

// Step 2: rebuild the native modules, for example node-pty, for Electron.
run('pnpm', ['exec', 'electron-builder', 'install-app-deps'])

// Step 3: make the node-pty helper programs executable.
// Without the execute bit, a PTY spawn fails with "posix_spawnp failed".
const prebuilds = join('node_modules', 'node-pty', 'prebuilds')
if (existsSync(prebuilds)) {
  for (const dir of readdirSync(prebuilds)) {
    const helper = join(prebuilds, dir, 'spawn-helper')
    if (existsSync(helper)) chmodSync(helper, 0o755)
  }
}
