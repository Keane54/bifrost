// Settings > Daily update: the labels of the rows and the pure helpers of the section.
import {
  type DailySource,
  type DailyUpdateSettings,
  hasReadWord,
  hasWriteWord,
  type McpInventory,
  toolPrefix,
  type WorkArea,
} from '../../../shared/daily-update'

// The labels of the rows. This list is the one source of the labels: the rows use these
// constants, and the search of Settings finds the rows by them.
export const DAILY_ROWS = {
  areas: 'Work areas',
  days: 'Days',
  deadline: 'Deadline',
  draftTime: 'Draft and first reminder',
  examples: 'Examples of your updates',
  format: 'Format',
  mergedPrs: 'Use merged PRs',
  model: 'Model',
  source: 'Ticket source',
  tools: 'Tools the run can use',
  you: 'You on the board',
} as const

export interface ToolRow {
  name: string
  // True when the name only reads. Bifrost ticks such a tool for a new source.
  proposed: boolean
  // True when the name has a write word. The run never gets such a tool.
  write: boolean
}

// The notes beside a tool that Bifrost does not propose.
export const MAY_CHANGE = 'May change things'
export const NEVER_USED = 'Bifrost never lets the run use this tool'

export interface ShownTool extends ToolRow {
  // True when the tool is in the saved list.
  on: boolean
}

export interface ServerChoice {
  name: string
  label: string
  disabled: boolean
}

// A new work area, on and empty. The user types its name.
export function newArea(): WorkArea {
  return {
    channel: '',
    description: '',
    id: crypto.randomUUID(),
    name: '',
    on: true,
    takesRest: false,
  }
}

// Only the area with this ID takes all other work.
export function setTakesRest(areas: readonly WorkArea[], id: string): WorkArea[] {
  return areas.map(area => ({ ...area, takesRest: area.id === id }))
}

// Mark one tool of the server with the prefix.
function toolRow(prefix: string, name: string): ToolRow {
  const write = hasWriteWord(prefix, name)
  return { name, proposed: !write && hasReadWord(prefix, name), write }
}

// The tools of a server, each marked when its name looks read-only or has a write word.
export function toolsForServer(inventory: McpInventory, server: string): ToolRow[] {
  const found = inventory.servers.find(item => item.name === server)
  if (!found) return []
  return found.tools.map(name => toolRow(toolPrefix(server), name))
}

// The note beside a tool, or null for a proposed tool.
export function toolNote(tool: ToolRow): string | null {
  if (tool.write) return NEVER_USED
  return tool.proposed ? null : MAY_CHANGE
}

// Change the ticket source. The tools become the proposed read tools of the new server.
// No server clears the tools.
export function chooseServer(
  settings: DailyUpdateSettings,
  inventory: McpInventory,
  server: string | null,
): DailyUpdateSettings {
  const tools =
    server === null
      ? []
      : toolsForServer(inventory, server)
          .filter(tool => tool.proposed)
          .map(tool => tool.name)
  return { ...settings, source: { server, tools } }
}

// The words for the status of a server.
export function statusWords(status: string): string {
  switch (status) {
    case 'connected':
      return 'connected'
    case 'needs-auth':
      return 'needs sign-in'
    case 'failed':
      return 'could not connect'
    case 'pending':
      return 'still connecting'
    case 'disabled':
      return 'turned off'
    default:
      return status
  }
}

// The servers of the inventory for the select. A server that is not connected cannot be chosen.
export function serverChoices(inventory: McpInventory): ServerChoice[] {
  return inventory.servers.map(server =>
    server.status === 'connected'
      ? { disabled: false, label: server.name, name: server.name }
      : {
          disabled: true,
          label: `${server.name} (${statusWords(server.status)})`,
          name: server.name,
        },
  )
}

// The tools to show for the source. With an inventory, all tools of the server. Saved tools that
// the inventory does not list stay in the list. With no inventory, only the saved tools.
// A tool with a write word never shows as ticked, because the run never gets it.
export function shownTools(inventory: McpInventory | null, source: DailySource): ShownTool[] {
  if (source.server === null) return []
  const prefix = toolPrefix(source.server)
  const saved = new Set(source.tools)
  const listed = inventory !== null ? toolsForServer(inventory, source.server) : []
  const names = new Set(listed.map(tool => tool.name))
  const rows = [
    ...listed,
    ...source.tools.filter(name => !names.has(name)).map(name => toolRow(prefix, name)),
  ]
  return rows.map(tool => ({ ...tool, on: !tool.write && saved.has(tool.name) }))
}

// Add or remove one tool. The order of the list stays.
export function toggleTool(tools: readonly string[], name: string, on: boolean): string[] {
  const rest = tools.filter(tool => tool !== name)
  return on ? [...rest, name] : rest
}

// The days as buttons, from Monday to Sunday. The number is Date.getDay().
export function dayChoices(): { day: number; label: string }[] {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
  return names.map((label, index) => ({ day: (index + 1) % 7, label }))
}

// Add or remove one day. The result is in the order of the week, Sunday first as getDay().
export function toggleDay(days: readonly number[], day: number): number[] {
  const next = days.includes(day) ? days.filter(item => item !== day) : [...days, day]
  return next.sort((a, b) => a - b)
}

// The most work areas that the settings accept.
export const MAX_AREAS = 10

// True when the page can add one more work area. Count the saved areas and the new ones.
export function canAddArea(count: number): boolean {
  return count < MAX_AREAS
}
