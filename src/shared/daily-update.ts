// The settings model of the Daily update. This module imports no library.
import { MODEL_VALUES, type ModelChoice } from './new-session'
import { isPlainObject } from './plain-object'

export interface WorkArea {
  id: string
  on: boolean
  name: string
  channel: string
  description: string
  // The area that gets all work that no other area claims. At most one area has it.
  takesRest: boolean
}

export interface DailyFormat {
  template: string
  examples: string[]
}

export interface DailySource {
  // The name of the MCP server, or null when the user chose none.
  server: string | null
  // Full tool names: mcp__<prefix>__<tool>.
  tools: string[]
}

export interface DailyUpdateSettings {
  source: DailySource
  you: string
  mergedPrs: boolean
  // Times as HH:MM, 24 hours.
  draftTime: string
  deadline: string
  // Numbers of Date.getDay(). Sunday is 0.
  days: number[]
  // '' means the default model of Claude Code.
  model: ModelChoice
  format: DailyFormat
  areas: WorkArea[]
}

// The MCP servers of the user's Claude Code, from the init event of a probe run.
export interface McpServerInfo {
  name: string
  status: string
  prefix: string
  tools: string[]
}
export interface McpInventory {
  servers: McpServerInfo[]
}

export const DEFAULT_TEMPLATE =
  '**Daily update**\n**Done since my last update**\n**Next**\n**Blocked or at risk**'

export const DEFAULT_DAILY_UPDATE: DailyUpdateSettings = {
  areas: [],
  days: [1, 2, 3, 4, 5],
  deadline: '10:00',
  draftTime: '09:30',
  format: { examples: [], template: DEFAULT_TEMPLATE },
  mergedPrs: true,
  model: '',
  source: { server: null, tools: [] },
  you: '',
}

const MAX_AREAS = 10
const MAX_NAME = 60
const MAX_CHANNEL = 80
const MAX_DESCRIPTION = 500
const MAX_TEMPLATE = 2000
const MAX_EXAMPLES = 3
const MAX_EXAMPLE = 4000
const MAX_YOU = 200
const MAX_TOOLS = 500
const MIN_GAP_MINUTES = 10

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/
const TOOL_NAME = /^mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+$/

const READ_WORDS = new Set(['list', 'get', 'search', 'query', 'read', 'find', 'diff', 'aggregate'])
const WRITE_WORDS = new Set(
  (
    'add create update delete replace remove move mark reorder batch set import execute send ' +
    'post assign close archive restore publish regenerate approve confirm convert revert ' +
    'complete tick run write edit upload merge sync'
  ).split(' '),
)

// The tool prefix of an MCP server. Each character that is not a letter, digit, _ or - becomes _.
export function toolPrefix(serverName: string): string {
  return `mcp__${serverName.replace(/[^A-Za-z0-9_-]/g, '_')}__`
}

// The words of a tool name after the prefix, in lower case. The name splits at _, at - and at
// each camelCase boundary. So getIssue gives get and issue.
function toolWords(prefix: string, tool: string): string[] {
  const name = tool.startsWith(prefix) ? tool.slice(prefix.length) : tool
  return name
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .split(/[\s_-]+/)
    .filter(word => word !== '')
    .map(word => word.toLowerCase())
}

// True when a word of the tool name can change things. The run never gets such a tool.
export function hasWriteWord(prefix: string, tool: string): boolean {
  return toolWords(prefix, tool).some(word => WRITE_WORDS.has(word))
}

// True when a word of the tool name only reads.
export function hasReadWord(prefix: string, tool: string): boolean {
  return toolWords(prefix, tool).some(word => READ_WORDS.has(word))
}

// Keep the tools of the prefix that only read. A tool with a write word is dropped.
export function proposeReadTools(prefix: string, tools: readonly string[]): string[] {
  return tools.filter(
    tool => tool.startsWith(prefix) && !hasWriteWord(prefix, tool) && hasReadWord(prefix, tool),
  )
}

const isTime = (value: unknown): value is string => typeof value === 'string' && TIME.test(value)

function minutesOf(time: string): number {
  return Number(time.slice(0, 2)) * 60 + Number(time.slice(3))
}

const inRange = (value: unknown, min: number, max: number): value is string =>
  typeof value === 'string' && value.length >= min && value.length <= max

function isDay(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 6
}

// The reasons that Settings shows. Each one says what is wrong and the limit.
const REASON = {
  area: "A work area isn't valid. Remove it and add it again.",
  areas: `You can have up to ${MAX_AREAS} work areas.`,
  channel: `A channel can have up to ${MAX_CHANNEL} characters.`,
  days: 'Pick at least one day.',
  description: `"Which work goes here" can have up to ${MAX_DESCRIPTION} characters.`,
  examples: 'You can add up to 3 examples, each up to 4,000 characters.',
  format: 'The format needs 1 to 2,000 characters.',
  gap: 'The deadline must be 10 minutes or more after the draft time.',
  mergedPrs: 'Turn Use merged PRs on or off.',
  model: 'Choose a model from the list.',
  name: `A name can have up to ${MAX_NAME} characters.`,
  noName: 'Each work area needs a name.',
  rest: 'Only one work area can take all other work.',
  sameArea: 'A work area is in the list twice. Remove one of them.',
  server: 'A server name can have up to 200 characters.',
  settings: "Bifrost couldn't read these settings.",
  source: "The ticket source isn't valid. Choose it again.",
  time: 'Enter each time as HH:MM, for example 09:30.',
  tools: 'Choose up to 500 tools, all from the ticket source.',
  you: `Your name, email or ID can have up to ${MAX_YOU} characters.`,
} as const

// Check one area. Give the area, or the reason why it is not good.
function checkArea(value: unknown): WorkArea | string {
  if (!isPlainObject(value)) return REASON.area
  const { id, on, name, channel, description, takesRest } = value
  if (!inRange(id, 1, 100) || typeof on !== 'boolean' || typeof takesRest !== 'boolean') {
    return REASON.area
  }
  if (name === '') return REASON.noName
  if (!inRange(name, 1, MAX_NAME)) return REASON.name
  if (!inRange(channel, 0, MAX_CHANNEL)) return REASON.channel
  if (!inRange(description, 0, MAX_DESCRIPTION)) return REASON.description
  return { channel, description, id, name, on, takesRest }
}

// Return a good area, or null.
function readArea(value: unknown): WorkArea | null {
  const area = checkArea(value)
  return typeof area === 'string' ? null : area
}

function readTools(value: unknown, server: string | null): string[] | null {
  if (!Array.isArray(value) || value.length > MAX_TOOLS || server === null) return null
  const prefix = toolPrefix(server)
  const ok = value.every(
    tool => typeof tool === 'string' && TOOL_NAME.test(tool) && tool.startsWith(prefix),
  )
  return ok ? (value as string[]) : null
}

function readExamples(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length > MAX_EXAMPLES) return null
  return value.every(item => inRange(item, 0, MAX_EXAMPLE)) ? (value as string[]) : null
}

function readDays(value: unknown): number[] | null {
  if (!Array.isArray(value) || value.length === 0 || !value.every(isDay)) return null
  return [...new Set(value as number[])].sort((a, b) => a - b)
}

function readServer(value: unknown): string | null | undefined {
  if (value === null) return null
  return inRange(value, 1, 200) ? value : undefined
}

// Read the stored daily update. Each bad part gets its default. The other parts stay.
export function parseDailyUpdate(value: unknown): DailyUpdateSettings {
  const result = structuredClone(DEFAULT_DAILY_UPDATE)
  if (!isPlainObject(value)) return result
  if (isPlainObject(value.source)) {
    const server = readServer(value.source.server)
    if (server) {
      result.source.server = server
      result.source.tools = readTools(value.source.tools, server) ?? []
    }
  }
  if (inRange(value.you, 0, MAX_YOU)) result.you = value.you
  if (typeof value.mergedPrs === 'boolean') result.mergedPrs = value.mergedPrs
  if (isTime(value.draftTime)) result.draftTime = value.draftTime
  if (isTime(value.deadline)) result.deadline = value.deadline
  if (minutesOf(result.deadline) - minutesOf(result.draftTime) < MIN_GAP_MINUTES) {
    result.draftTime = DEFAULT_DAILY_UPDATE.draftTime
    result.deadline = DEFAULT_DAILY_UPDATE.deadline
  }
  result.days = readDays(value.days) ?? result.days
  if ((MODEL_VALUES as readonly unknown[]).includes(value.model)) {
    result.model = value.model as ModelChoice
  }
  if (isPlainObject(value.format)) {
    if (inRange(value.format.template, 1, MAX_TEMPLATE)) {
      result.format.template = value.format.template
    }
    result.format.examples = readExamples(value.format.examples) ?? []
  }
  if (Array.isArray(value.areas)) {
    const seen = new Set<string>()
    let restTaken = false
    for (const item of value.areas) {
      const found = readArea(item)
      if (!found || seen.has(found.id) || result.areas.length >= MAX_AREAS) continue
      seen.add(found.id)
      if (found.takesRest && restTaken) found.takesRest = false
      restTaken ||= found.takesRest
      result.areas.push(found)
    }
  }
  return result
}

type CheckResult = { ok: true; value: DailyUpdateSettings } | { ok: false; reason: string }

const no = (reason: string): CheckResult => ({ ok: false, reason })

// Check a daily update from a patch. Anything bad refuses the full value.
export function checkDailyUpdate(value: unknown): CheckResult {
  if (!isPlainObject(value)) return no(REASON.settings)
  const { source, format, areas } = value
  if (!isPlainObject(source)) return no(REASON.source)
  const server = readServer(source.server)
  if (server === undefined) return no(REASON.server)
  const tools = server === null ? [] : readTools(source.tools, server)
  if (!tools || (server === null && !(Array.isArray(source.tools) && source.tools.length === 0))) {
    return no(REASON.tools)
  }
  if (!inRange(value.you, 0, MAX_YOU)) return no(REASON.you)
  if (typeof value.mergedPrs !== 'boolean') return no(REASON.mergedPrs)
  if (!isTime(value.draftTime) || !isTime(value.deadline)) return no(REASON.time)
  if (minutesOf(value.deadline) - minutesOf(value.draftTime) < MIN_GAP_MINUTES) {
    return no(REASON.gap)
  }
  const days = readDays(value.days)
  if (!days || days.length !== (value.days as unknown[]).length) return no(REASON.days)
  if (!(MODEL_VALUES as readonly unknown[]).includes(value.model)) return no(REASON.model)
  if (!isPlainObject(format) || !inRange(format.template, 1, MAX_TEMPLATE)) {
    return no(REASON.format)
  }
  const examples = readExamples(format.examples)
  if (!examples) return no(REASON.examples)
  if (!Array.isArray(areas)) return no(REASON.settings)
  if (areas.length > MAX_AREAS) return no(REASON.areas)
  const list: WorkArea[] = []
  for (const item of areas) {
    const found = checkArea(item)
    if (typeof found === 'string') return no(found)
    if (list.some(other => other.id === found.id)) return no(REASON.sameArea)
    list.push(found)
  }
  if (list.filter(item => item.takesRest).length > 1) return no(REASON.rest)
  return {
    ok: true,
    value: {
      areas: list,
      days,
      deadline: value.deadline,
      draftTime: value.draftTime,
      format: { examples, template: format.template },
      mergedPrs: value.mergedPrs,
      model: value.model as ModelChoice,
      source: { server, tools },
      you: value.you,
    },
  }
}
