// The arguments of the claude -p run. The run may use only the allowed read tools of one MCP
// server. The run has no write tool. Bifrost denies all other tools of that server and all other
// servers.

import { hasWriteWord } from '../../shared/daily-update'
import type { ModelChoice } from '../../shared/new-session'
import type { McpInventory } from './mcp-inventory'

// The chosen tools that the server has now. A tool with a write word never goes in, also when the
// user ticked it.
export function allowedNow(
  inv: McpInventory,
  server: string | null,
  chosen: readonly string[],
): string[] {
  const info = server === null ? undefined : inv.servers.find(s => s.name === server)
  if (!info) return []
  return chosen.filter(tool => info.tools.includes(tool) && !hasWriteWord(info.prefix, tool))
}

// The rule for a whole server: its prefix without the last __.
const serverRule = (prefix: string): string => prefix.replace(/__$/, '')

// Give each other tool of the chosen server and each of its tools with a write word, then a rule
// for each other server. With no server, give a rule for every server.
export function denyList(
  inv: McpInventory,
  server: string | null,
  allowed: readonly string[],
): string[] {
  const deny: string[] = []
  for (const info of inv.servers) {
    if (info.name !== server) continue
    for (const tool of info.tools) {
      if (!allowed.includes(tool) || hasWriteWord(info.prefix, tool)) deny.push(tool)
    }
  }
  for (const info of inv.servers) {
    if (info.name !== server) deny.push(serverRule(info.prefix))
  }
  return deny
}

// Both folders are real paths (no link). A path rule with a leading / and an absolute path gives
// the // form.
export function runArgs(o: {
  ioDir: string
  pluginDir: string
  model: ModelChoice
  allowed: string[]
  deny: string[]
  prompt: string
}): string[] {
  const args = [
    '-p',
    '--output-format',
    'json',
    '--tools',
    'Read,Skill',
    '--permission-mode',
    'dontAsk',
    '--plugin-dir',
    o.pluginDir,
    '--add-dir',
    o.ioDir,
    '--allowedTools',
    ...o.allowed,
    'Skill',
    `Read(/${o.ioDir}/**)`,
    `Read(/${o.pluginDir}/**)`,
  ]
  if (o.deny.length > 0) args.push('--disallowedTools', ...o.deny)
  args.push('--settings', '{"disableAllHooks":true}')
  if (o.model !== '') args.push('--model', o.model)
  args.push(o.prompt)
  return args
}
