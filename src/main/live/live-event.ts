// The lines of the Live details mod.
//
// The mod sends one JSON object for each event. Each object has v (always 1), kind, sid, at
// (milliseconds) and seq (the order number of the session). This table is the contract with the
// mod (hooks/register.ts). The mod sends facts. This file maps the facts to events.
//
// | kind          | Other fields                                     | Result                      |
// | ------------- | ------------------------------------------------ | --------------------------- |
// | session.start | none                                             | SessionStart                |
// | session.end   | reason (string)                                  | SessionEnd                  |
// | turn.start    | none                                             | UserPromptSubmit            |
// | ask           | none                                             | PreToolUse (AskUserQuestion)|
// | tool.done     | tool (string)                                    | PostToolUse                 |
// | permission    | tool (string)                                    | PermissionRequest           |
// | turn.complete | reason: answer or refusal, answer (string)       | Stop                        |
// | turn.complete | reason: aborted, answer (string)                 | TurnAborted                 |
// | turn.complete | reason: error                                    | StopFailure                 |
// | stop.failure  | error (string, optional)                         | StopFailure                 |
// | usage         | model, context { tokens?, window, percent? },    | usage line                  |
// |               | costUsd?, rateLimits [{ kind, percentUsed,       |                             |
// |               | resetsAt? }]                                     |                             |
//
// A bad line gives null. A bad field of a usage line is left out and the line stays.

import type { RateLimits, RateWindow } from '../../shared/types'
import { isUuid } from '../../shared/uuid'
import type { HookEvent } from '../registry/hook-event'

export const LIVE_VERSION = 1
export const ANSWER_MAX = 4000
export const TEXT_MAX = 200
export const AT_DRIFT_MS = 10_000

export interface LiveUsage {
  model?: string
  contextPercent?: number
  contextTokens?: number
  contextWindow?: number
  costUsd?: number
  rateLimits?: RateLimits
}

export type LiveEvent =
  | { type: 'state'; event: HookEvent }
  | { type: 'usage'; sessionId: string; at: number; usage: LiveUsage }

type Raw = Record<string, unknown>

function isRecord(value: unknown): value is Raw {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function cut(value: unknown, max: number): string | undefined {
  return typeof value === 'string' ? value.slice(0, max) : undefined
}

function inRange(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max
}

function readWindow(value: unknown): RateWindow | undefined {
  if (!isRecord(value)) return undefined
  if (!inRange(value.percentUsed, 0, 100)) return undefined
  if (typeof value.resetsAt !== 'string') return undefined
  const resetsAt = Date.parse(value.resetsAt)
  if (!Number.isFinite(resetsAt)) return undefined
  return { resetsAt, usedPercent: value.percentUsed }
}

function readRateLimits(value: unknown): RateLimits | undefined {
  if (!Array.isArray(value)) return undefined
  const limits: RateLimits = {}
  for (const item of value) {
    if (!isRecord(item)) continue
    const window = readWindow(item)
    if (!window) continue
    if (item.kind === 'five_hour') limits.fiveHour = window
    else if (item.kind === 'seven_day') limits.sevenDay = window
  }
  return limits.fiveHour || limits.sevenDay ? limits : undefined
}

function readUsage(raw: Raw): LiveUsage {
  const usage: LiveUsage = {}
  const model = cut(raw.model, TEXT_MAX)
  if (model) usage.model = model
  if (isRecord(raw.context)) {
    const { tokens, window, percent } = raw.context
    if (typeof tokens === 'number' && Number.isSafeInteger(tokens) && tokens >= 0) {
      usage.contextTokens = tokens
    }
    if (typeof window === 'number' && Number.isFinite(window) && window > 0) {
      usage.contextWindow = window
    }
    if (inRange(percent, 0, 100)) usage.contextPercent = percent
  }
  if (typeof raw.costUsd === 'number' && Number.isFinite(raw.costUsd) && raw.costUsd >= 0) {
    usage.costUsd = raw.costUsd
  }
  const rateLimits = readRateLimits(raw.rateLimits)
  if (rateLimits) usage.rateLimits = rateLimits
  return usage
}

// Read one line of the mod. receivedAt is the time of receipt in milliseconds.
export function parseLiveLine(text: string, receivedAt: number): LiveEvent | null {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    return null
  }
  if (!isRecord(data)) return null
  if (data.v !== LIVE_VERSION) return null
  if (!isUuid(data.sid)) return null
  if (typeof data.at !== 'number' || !Number.isFinite(data.at)) return null
  const sessionId = data.sid
  const at = Math.abs(data.at - receivedAt) > AT_DRIFT_MS ? receivedAt : data.at

  if (data.kind === 'usage') {
    return { at, sessionId, type: 'usage', usage: readUsage(data) }
  }

  const event = readState(data, sessionId, at)
  if (!event) return null
  if (typeof data.seq === 'number' && Number.isSafeInteger(data.seq) && data.seq >= 0) {
    event.seq = data.seq
  }
  return { event, type: 'state' }
}

function readState(raw: Raw, sessionId: string, at: number): HookEvent | null {
  const base = { at, sessionId }
  const tool = cut(raw.tool, TEXT_MAX)
  const answer = cut(raw.answer, ANSWER_MAX)
  switch (raw.kind) {
    case 'session.start':
      return { ...base, name: 'SessionStart' }
    case 'session.end':
      return typeof raw.reason === 'string' ? { ...base, name: 'SessionEnd' } : null
    case 'turn.start':
      return { ...base, name: 'UserPromptSubmit' }
    case 'ask':
      return { ...base, name: 'PreToolUse', toolName: 'AskUserQuestion' }
    case 'tool.done':
      return tool === undefined ? null : { ...base, name: 'PostToolUse', toolName: tool }
    case 'permission':
      return tool === undefined ? null : { ...base, name: 'PermissionRequest', toolName: tool }
    case 'stop.failure':
      return { ...base, name: 'StopFailure' }
    case 'turn.complete': {
      const withAnswer = (name: 'Stop' | 'TurnAborted'): HookEvent => {
        const event: HookEvent = { ...base, name }
        if (answer) event.lastAssistantMessage = answer
        return event
      }
      if (raw.reason === 'answer' || raw.reason === 'refusal') return withAnswer('Stop')
      if (raw.reason === 'aborted') return withAnswer('TurnAborted')
      if (raw.reason === 'error') return { ...base, name: 'StopFailure' }
      return null
    }
    default:
      return null
  }
}
