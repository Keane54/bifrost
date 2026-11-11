import { describe, expect, test } from 'vitest'
import { handOverPrompt, NOTE_END, NOTE_START } from '../../../src/main/handover/prompt'
import { maskSecrets, readReply } from '../../../src/main/handover/reply'

const ID = 'ab12cd34'
const MODEL = 'claude-opus-5-5'

// One transcript line.
function line(entry: unknown): string {
  return `${JSON.stringify(entry)}\n`
}

// The request entry. The real prompt also holds both markers, on lines of their own.
function request(extra: Record<string, unknown> = {}): string {
  return line({
    message: { content: handOverPrompt('The rules.', ID), role: 'user' },
    permissionMode: 'plan',
    type: 'user',
    ...extra,
  })
}

function assistant(content: unknown, extra: Record<string, unknown> = {}): string {
  return line({
    message: { content, model: MODEL, role: 'assistant' },
    type: 'assistant',
    ...extra,
  })
}

function text(value: string): { type: string; text: string } {
  return { text: value, type: 'text' }
}

const TURN_END = line({ durationMs: 1200, subtype: 'turn_duration', type: 'system' })

// A message that the user typed during the turn. Claude Code delivers it in the turn.
function queued(commandMode?: string): string {
  return line({
    attachment: { commandMode, prompt: 'Wait, stop.', type: 'queued_command' },
    type: 'attachment',
  })
}

// The note of a background task. Claude Code also delivers it as a queued command.
const TASK_NOTE = line({
  attachment: {
    commandMode: 'task-notification',
    prompt: '<task-notification>done</task-notification>',
    type: 'queued_command',
  },
  type: 'attachment',
})

// A message that the user typed.
const TYPED = line({ message: { content: 'Wait, stop.', role: 'user' }, type: 'user' })

// The reason of a failure.
function reasonOf(tail: string): string {
  const state = readReply(tail, ID)
  return state.kind === 'failed' ? state.reason : `not failed: ${state.kind}`
}

// A reply with a note between the markers, in one text block.
function noteReply(note: string, extra: Record<string, unknown> = {}): string {
  return assistant([text(`Here is the note.\n${NOTE_START}\n${note}\n${NOTE_END}`)], extra)
}

describe('readReply: a good reply', () => {
  test('a reply over two assistant entries gives the joined note, the model and the mode', () => {
    const tail =
      request() +
      assistant([{ signature: 's', thinking: 'Plan the note.', type: 'thinking' }]) +
      assistant([text(`Here is the note.\n${NOTE_START}\n# Hand-over: fix login\n`)]) +
      assistant([text(`## Goal and scope\nfix the login\n${NOTE_END}\nDone.`)], {
        requestedModel: 'opus[1m]',
      }) +
      TURN_END
    expect(readReply(tail, ID)).toEqual({
      kind: 'done',
      model: 'opus[1m]',
      note: '# Hand-over: fix login\n\n## Goal and scope\nfix the login',
      permissionMode: 'plan',
    })
  })

  test('the model of the message counts when the entry has no requested model', () => {
    const state = readReply(request() + noteReply('the note') + TURN_END, ID)
    expect(state).toEqual({ kind: 'done', model: MODEL, note: 'the note', permissionMode: 'plan' })
  })

  test('the model is from the last assistant entry, and <synthetic> does not count', () => {
    const synthetic = line({
      message: { content: [text(`${NOTE_START}\nn\n${NOTE_END}`)], model: '<synthetic>' },
      requestedModel: '<synthetic>',
      type: 'assistant',
    })
    const tail =
      request() +
      assistant([text('Part one.')]) +
      assistant([text('Part two.')], { requestedModel: 'sonnet' }) +
      synthetic +
      TURN_END
    // The last entry has no model that counts. So the model of the entry before it counts.
    expect(readReply(tail, ID)).toEqual(expect.objectContaining({ kind: 'done', model: 'sonnet' }))
  })

  test('a request entry with no permission mode gives null', () => {
    const state = readReply(request({ permissionMode: undefined }) + noteReply('n') + TURN_END, ID)
    expect(state).toEqual(expect.objectContaining({ kind: 'done', permissionMode: null }))
  })

  test('a request in text blocks counts', () => {
    const tail =
      line({
        message: { content: [text(handOverPrompt('The rules.', ID))], role: 'user' },
        type: 'user',
      }) +
      noteReply('the note') +
      TURN_END
    expect(readReply(tail, ID)).toEqual(expect.objectContaining({ kind: 'done', note: 'the note' }))
  })

  test('sidechain entries, metadata entries and allowed user entries are skipped', () => {
    const tail =
      line({ messageId: 'm1', type: 'file-history-snapshot' }) +
      request() +
      line({ type: 'progress' }) +
      line({ attachment: { type: 'edited_text_file' }, type: 'attachment' }) +
      TASK_NOTE +
      line({ operation: 'enqueue', type: 'queue-operation' }) +
      line({ content: 'Compacted', subtype: 'compact_boundary', type: 'system' }) +
      // A sidechain entry is not part of this conversation. It is not checked and not used.
      assistant('not an array', { isSidechain: true }) +
      assistant([text(`${NOTE_START}\nsidechain note\n${NOTE_END}`)], { isSidechain: true }) +
      assistant([{ id: 't1', input: {}, name: 'Read', type: 'tool_use' }]) +
      line({
        message: { content: [{ content: 'ok', tool_use_id: 't1', type: 'tool_result' }] },
        type: 'user',
      }) +
      line({ isMeta: true, message: { content: 'Caveat: a meta message.' }, type: 'user' }) +
      assistant([{ data: 'x', type: 'redacted_thinking' }]) +
      noteReply('the real note') +
      TURN_END
    expect(readReply(tail, ID)).toEqual(
      expect.objectContaining({ kind: 'done', note: 'the real note' }),
    )
  })

  test('blank lines are skipped', () => {
    const tail = `${request()}\n${noteReply('the note')}\n${TURN_END}`
    expect(readReply(tail, ID)).toEqual(expect.objectContaining({ kind: 'done' }))
  })

  test('markers with spaces around them count', () => {
    const reply = assistant([text(`  ${NOTE_START}  \nthe note\n${NOTE_END} `)])
    expect(readReply(request() + reply + TURN_END, ID)).toEqual(
      expect.objectContaining({ kind: 'done', note: 'the note' }),
    )
  })

  test('entries after the turn end that are not a new message are skipped', () => {
    const tail =
      request() +
      noteReply('the note') +
      TURN_END +
      line({ operation: 'enqueue', type: 'queue-operation' }) +
      TASK_NOTE +
      assistant('not checked') +
      line({ isMeta: true, message: { content: 'meta' }, type: 'user' }) +
      TURN_END
    expect(readReply(tail, ID)).toEqual(expect.objectContaining({ kind: 'done', note: 'the note' }))
  })
})

describe('readReply: the request line', () => {
  test('the request is a whole line, so a longer ID does not match', () => {
    const tail = request() + noteReply('the note') + TURN_END
    expect(readReply(tail, 'ab12')).toEqual({ kind: 'failed', reason: reasonOf(TURN_END) })
    const inLine = line({
      message: { content: `See Bifrost hand-over request ${ID} for this.`, role: 'user' },
      type: 'user',
    })
    expect(readReply(inLine + noteReply('the note'), ID)).toEqual({ kind: 'pending' })
  })

  test('the request line can be any line of the user text', () => {
    const later = line({
      message: { content: `Text before.\r\nBifrost hand-over request ${ID}\nMore.`, role: 'user' },
      type: 'user',
    })
    expect(readReply(later + noteReply('the note') + TURN_END, ID)).toEqual(
      expect.objectContaining({ kind: 'done', note: 'the note' }),
    )
  })
})

describe('readReply: an older note (Review Focus 2)', () => {
  test('a marker pair before the request is not used', () => {
    const old = noteReply('the old note')
    const tail = old + request() + assistant([text('I have no note.')]) + TURN_END
    expect(readReply(tail, ID).kind).toBe('failed')
    const good = old + request() + noteReply('the new note') + TURN_END
    expect(readReply(good, ID)).toEqual(
      expect.objectContaining({ kind: 'done', note: 'the new note' }),
    )
  })

  test('the request of an earlier hand-over is not the request', () => {
    const earlier = line({
      message: { content: handOverPrompt('The rules.', 'zz99zz99') },
      type: 'user',
    })
    expect(readReply(earlier + noteReply('the old note'), ID)).toEqual({ kind: 'pending' })
  })
})

describe('readReply: a failure', () => {
  test('a line that is not JSON fails', () => {
    for (const bad of ['{"type":"user"', 'not json', '[1]', 'null', '"text"', '{"type":1}']) {
      const state = readReply(`${request()}${bad}\n${noteReply('n')}${TURN_END}`, ID)
      expect(state.kind, bad).toBe('failed')
    }
    // Also before the request.
    expect(readReply(`{}\n${request()}`, ID).kind).toBe('failed')
  })

  test('an unknown block type fails', () => {
    const tail = request() + assistant([{ source: {}, type: 'image' }]) + noteReply('n') + TURN_END
    expect(readReply(tail, ID).kind).toBe('failed')
  })

  test('a text block without text fails', () => {
    for (const block of [{ type: 'text' }, { text: 5, type: 'text' }, 'text', null]) {
      const tail = request() + assistant([block]) + noteReply('n') + TURN_END
      expect(readReply(tail, ID).kind, JSON.stringify(block)).toBe('failed')
    }
  })

  test('an assistant entry without a content array fails', () => {
    for (const entry of [
      { message: { content: 'text' }, type: 'assistant' },
      { message: 'text', type: 'assistant' },
      { type: 'assistant' },
    ]) {
      const tail = request() + line(entry) + noteReply('n') + TURN_END
      expect(readReply(tail, ID).kind, JSON.stringify(entry)).toBe('failed')
    }
  })

  test('a second user message fails (Review Focus 3)', () => {
    const typed = line({ message: { content: 'Wait, stop.', role: 'user' }, type: 'user' })
    expect(readReply(request() + noteReply('n') + typed + TURN_END, ID).kind).toBe('failed')
    // The text that Claude Code writes after an Interrupt.
    const interrupt = line({
      message: { content: [text('[Request interrupted by user]')], role: 'user' },
      type: 'user',
    })
    // The failure does not wait for a turn end.
    expect(readReply(request() + interrupt, ID).kind).toBe('failed')
    const result = readReply(request() + interrupt, ID)
    expect(result.kind === 'failed' && result.reason).toBe('the session was interrupted')
    // A tool result next to a text block is a user message.
    const mixed = line({
      message: { content: [{ content: 'ok', tool_use_id: 't1', type: 'tool_result' }, text('x')] },
      type: 'user',
    })
    expect(readReply(request() + mixed + noteReply('n') + TURN_END, ID).kind).toBe('failed')
  })

  test('a message that the user typed during the turn fails (Review Focus 3)', () => {
    const typed = reasonOf(request() + TYPED)
    expect(typed).toContain('a new message')
    for (const mode of ['prompt', 'bash', undefined]) {
      expect(reasonOf(request() + queued(mode)), String(mode)).toBe(typed)
      const done = request() + noteReply('n') + queued(mode) + TURN_END
      expect(reasonOf(done), String(mode)).toBe(typed)
    }
    // The note of a background task is not a message from the user.
    expect(readReply(request() + TASK_NOTE + noteReply('n') + TURN_END, ID).kind).toBe('done')
    // Before the request, a queued message does not count.
    expect(readReply(queued('prompt') + request() + noteReply('n') + TURN_END, ID).kind).toBe(
      'done',
    )
  })

  test('a new message after the turn end fails (Review Focus 3)', () => {
    const good = request() + noteReply('n') + TURN_END
    const typed = reasonOf(request() + TYPED)
    expect(reasonOf(good + TYPED)).toBe(typed)
    expect(reasonOf(good + queued('prompt'))).toBe(typed)
    // A new turn that the typed message starts.
    expect(reasonOf(good + TYPED + assistant([text('OK.')]) + TURN_END)).toBe(typed)
  })

  test('no turn end gives pending', () => {
    expect(readReply('', ID)).toEqual({ kind: 'pending' })
    expect(readReply(line({ type: 'file-history-snapshot' }), ID)).toEqual({ kind: 'pending' })
    expect(readReply(request(), ID)).toEqual({ kind: 'pending' })
    expect(readReply(request() + noteReply('n'), ID)).toEqual({ kind: 'pending' })
  })

  test('a turn end with no request before it fails', () => {
    expect(readReply(TURN_END + request() + noteReply('n') + TURN_END, ID).kind).toBe('failed')
  })

  test('no markers fails', () => {
    const tail = request() + assistant([text('# Hand-over: x\nthe note')]) + TURN_END
    expect(readReply(tail, ID).kind).toBe('failed')
    // A marker inside a line is not a marker line.
    const inline = assistant([text(`The note goes between ${NOTE_START} and ${NOTE_END}.`)])
    expect(readReply(request() + inline + TURN_END, ID).kind).toBe('failed')
  })

  test('two start lines, two end lines, or the end before the start fails', () => {
    for (const reply of [
      `${NOTE_START}\n${NOTE_START}\nnote\n${NOTE_END}`,
      `${NOTE_START}\nnote\n${NOTE_END}\n${NOTE_END}`,
      `${NOTE_START}\nnote\n${NOTE_END}\n${NOTE_START}\nnote\n${NOTE_END}`,
      `${NOTE_END}\nnote\n${NOTE_START}`,
      `${NOTE_START}\nnote`,
    ]) {
      const tail = request() + assistant([text(reply)]) + TURN_END
      expect(readReply(tail, ID).kind, reply).toBe('failed')
    }
  })

  test('an empty note fails', () => {
    const reply = assistant([text(`${NOTE_START}\n  \n\n${NOTE_END}`)])
    expect(readReply(request() + reply + TURN_END, ID).kind).toBe('failed')
  })

  test('no model fails', () => {
    const reply = noteReply('the note').replace(`"model":"${MODEL}"`, '"model":"<synthetic>"')
    expect(readReply(request() + reply + TURN_END, ID).kind).toBe('failed')
    const none = line({
      message: { content: [text(`${NOTE_START}\nn\n${NOTE_END}`)] },
      type: 'assistant',
    })
    expect(readReply(request() + none + TURN_END, ID).kind).toBe('failed')
  })

  test('a failure has a reason', () => {
    const state = readReply(TURN_END, ID)
    expect(state.kind === 'failed' && state.reason.length > 0).toBe(true)
  })
})

describe('maskSecrets', () => {
  // The test makes each value at run time, so that no scanner reads a fixed token in this file.
  const values = [
    `ghp_${'a1B2'.repeat(9)}`,
    `gho_${'a'.repeat(20)}`,
    `ghs_${'Z9'.repeat(18)}`,
    `ghu_${'x'.repeat(40)}`,
    `github_pat_${'11ABC_'.repeat(12)}`,
    `sk-ant-api03-${'aB3_-'.repeat(10)}`,
    `AKIA${'ABCDEFGH12345678'}`,
    `xoxb-${'1234567890'}-abc`,
    `xoxp-${'12-34'.repeat(4)}`,
  ]

  test('each pattern is replaced', () => {
    for (const value of values) {
      expect(maskSecrets(`token: ${value} end`), value).toBe('token: [secret removed] end')
    }
  })

  test('all values in one text are replaced', () => {
    expect(maskSecrets(values.join('\n'))).toBe(values.map(() => '[secret removed]').join('\n'))
  })

  test('short values and normal text stay', () => {
    const text = 'ghp_short sk-ant-x AKIA123 xoxb-1 branch gh-pages and the github_pat_ docs'
    expect(maskSecrets(text)).toBe(text)
  })
})
