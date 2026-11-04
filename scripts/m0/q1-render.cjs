// M0 questions 1 and 2: render an attached session through node-pty and xterm.js.
// Usage: q1-render.cjs <short id of a bifrost-test- session> [--skip-prompts]
// With --skip-prompts the script types nothing. It only attaches, resizes and scrolls.
// The script attaches at 120 x 32 and records the escape sequences.
// It looks for the statusline text on the screen.
// It types two prompts, sends mouse wheel events and resizes the PTY.
// At the end it sends SIGHUP to its own attach client and reads the session status.
'use strict'
/* eslint-disable @typescript-eslint/no-require-imports, @typescript-eslint/explicit-function-return-type, no-control-regex -- CommonJS script for Node. The regexes match escape sequences. */
const L = require('./lib.cjs')
const { TestPty, log, sleep, writeOut, analyseSequences, stripAnsi } = L

// Count the colour modes of the cells on the screen.
function colourStats(term) {
  const b = term.buffer.active
  const stats = { rgbFg: 0, paletteFg: 0, defaultFg: 0, rgbBg: 0, paletteBg: 0, samplesRgb: [] }
  for (let y = 0; y < term.rows; y++) {
    const line = b.getLine(b.viewportY + y)
    if (!line) continue
    for (let x = 0; x < term.cols; x++) {
      const c = line.getCell(x)
      if (!c || c.getChars() === '' || c.getChars() === ' ') continue
      if (c.isFgRGB()) {
        stats.rgbFg++
        const hex = '#' + c.getFgColor().toString(16).padStart(6, '0')
        if (stats.samplesRgb.length < 12 && !stats.samplesRgb.includes(hex))
          stats.samplesRgb.push(hex)
      } else if (c.isFgPalette()) stats.paletteFg++
      else stats.defaultFg++
      if (c.isBgRGB()) stats.rgbBg++
      else if (c.isBgPalette()) stats.paletteBg++
    }
  }
  return stats
}

// Find the widest run of box characters on the screen.
function widestRule(lines) {
  let best = 0
  for (const l of lines) {
    const m = l.match(/[─━═]{4,}/g)
    if (m) for (const s of m) best = Math.max(best, s.length)
  }
  return best
}

async function resizeStep(p, cols, rows, name) {
  const mark = p.mark()
  const t = Date.now()
  p.resize(cols, rows)
  const q = await p.waitQuiet(800, 8000, false)
  const out = p.since(mark)
  const lines = await p.screenLines()
  const res = {
    to: `${cols}x${rows}`,
    firstByteMs: null,
    quietAfterMs: Date.now() - t,
    quiet: q.ok,
    seq: analyseSequences(out),
    widestRule: widestRule(lines),
    bottomLines: lines.slice(-4),
    nonEmptyLines: lines.filter((l) => l.trim()).length
  }
  const firstChunk = p.chunks.find((c) => c.ms >= t - p.t0)
  if (firstChunk) res.firstByteMs = firstChunk.ms - (t - p.t0)
  writeOut(`${name}.raw`, out)
  writeOut(`${name}.screen.txt`, lines.join('\n'))
  log(
    `resize ${res.to}: ${out.length} bytes, first byte ${res.firstByteMs} ms, rule ${res.widestRule}, 2J ${res.seq.clearScreen}`
  )
  return res
}

;(async () => {
  const id = process.argv[2]
  if (!id) throw new Error('usage: q1-render.cjs <short id>')
  const result = {}
  const p = await TestPty.attach({ id })
  const ready = await p.waitQuiet(1500, 30000)
  result.attach = { firstOutputMs: p.firstOutputMs, ready, bufferType: p.bufferType() }
  log(
    `attach: first output ${p.firstOutputMs} ms, ready ${JSON.stringify(ready)}, buffer ${p.bufferType()}`
  )
  result.initialSeq = analyseSequences(p.raw)
  result.initialReplies = p.replies.map((r) => ({ ms: r.ms, d: JSON.stringify(r.d) }))
  result.modes = p.modes()
  await p.save(process.argv.includes('--skip-prompts') ? 'q1b-attach-initial' : 'q1-attach-initial')
  const initialLines = await p.screenLines()

  // Question 2: look for the text that the statusline command prints.
  const screen = initialLines.join('\n')
  const plain = stripAnsi(p.raw)
  result.statusline = {
    screenHasHaiku: /Haiku/i.test(screen),
    screenHasSandbox: /m0-sandbox/.test(screen),
    screenHasPercent: /\d+%/.test(screen),
    rawHasHaiku: /Haiku/i.test(plain),
    rawHasOrangeBadge: /\x1b\[48;5;\d+;38;5;16m [^\x1b]*Haiku/i.test(p.raw),
    linesWithHaiku: initialLines.map((l, i) => ({ i, l })).filter((x) => /Haiku/i.test(x.l)),
    bottomLines: initialLines.slice(-6)
  }
  log('statusline:', result.statusline)

  // Watch the bottom rows for 6 more seconds. The statusline can come late.
  await sleep(6000)
  result.statusline.bottomLinesLater = (await p.screenLines()).slice(-6)
  result.statusline.rawHasPercentLater = /\d+%/.test(stripAnsi(p.raw))

  const skipPrompts = process.argv.includes('--skip-prompts')
  if (!skipPrompts) {
    // Question 1: colours. Ask for a markdown table.
    const m1 = p.mark()
    await p.typeLine('Show a table of three colours in markdown.')
    result.colourTurn = await L.waitTurn({ id }, { timeout: 90000 })
    await p.waitQuiet(1500, 15000)
    result.colourSeq = analyseSequences(p.since(m1))
    result.colourCells = colourStats(p.term)
    await p.save('q1-colours')
    log('colour turn:', result.colourTurn.trace, 'cells:', result.colourCells)

    // A long reply, so that the mouse wheel has something to scroll.
    await p.typeLine('List the numbers 1 to 80, one number per line, and nothing else.')
    result.longTurn = await L.waitTurn({ id }, { timeout: 90000 })
    await p.waitQuiet(1500, 15000)
    await p.save('q1-long')
  }
  const tag = skipPrompts ? 'q1b' : 'q1'

  // Resize the PTY and the xterm.js screen together, at the bottom of the view.
  result.resize = []
  result.resize.push(await resizeStep(p, 100, 30, `${tag}-resize-100x30`))
  result.resize.push(await resizeStep(p, 80, 24, `${tag}-resize-80x24`))
  result.resize.push(await resizeStep(p, 120, 32, `${tag}-resize-120x32`))
  result.afterResizeColours = colourStats(p.term)

  // Mouse wheel. Send wheel-up events in the encoding that the app asked for.
  const modes = p.modes()
  result.mouse = {
    trackingMode: modes.mouseTrackingMode,
    sgr1006: !!result.initialSeq.privateModes['?1006h']
  }
  const before = await p.screenLines()
  const wheel = (button) =>
    result.mouse.sgr1006
      ? `\x1b[<${button};60;15M`
      : `\x1b[M${String.fromCharCode(32 + button)}${String.fromCharCode(32 + 60)}${String.fromCharCode(32 + 15)}`
  const mw = p.mark()
  if (modes.mouseTrackingMode !== 'none') {
    for (let i = 0; i < 5; i++) {
      await p.write(wheel(64))
      await sleep(120)
    }
    await p.waitQuiet(800, 8000, false)
    const after = await p.screenLines()
    result.mouse.wheelUp = {
      bytesBack: p.since(mw).length,
      screenChanged: before.join('\n') !== after.join('\n'),
      topBefore: before.slice(0, 4),
      topAfter: after.slice(0, 4)
    }
    writeOut(`${tag}-wheel-up.screen.txt`, after.join('\n'))
    const md = p.mark()
    for (let i = 0; i < 5; i++) {
      await p.write(wheel(65))
      await sleep(120)
    }
    await p.waitQuiet(800, 8000, false)
    const back = await p.screenLines()
    writeOut(`${tag}-wheel-down.screen.txt`, back.join('\n'))
    result.mouse.wheelDown = {
      bytesBack: p.since(md).length,
      backToStart: back.join('\n') === before.join('\n')
    }
  } else {
    result.mouse.note = 'The app did not turn on mouse tracking. No wheel events sent.'
  }
  log('mouse:', result.mouse)

  // Close the attach client with SIGHUP. Then read the session status.
  p.lock('close')
  p.closeAttach('SIGHUP')
  const ex = await Promise.race([p.exited, sleep(5000).then(() => null)])
  result.close = { method: 'SIGHUP to the attach client', exit: ex }
  await sleep(1000)
  const e = (await L.listAgents()).find((x) => x.id === id)
  result.close.sessionAfter = e || null
  log('after close:', result.close)
  await p.save(`${tag}-final`)
  writeOut(`${tag}-result.json`, result)
  log(`saved ${tag}-result.json`)
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
