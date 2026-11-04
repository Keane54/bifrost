// M0 question 2: measure when the statusline first shows in an attached session.
// Usage: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/watch-statusline.ts <short id of a bifrost-test- session> [seconds]
//    or: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/watch-statusline.ts --start <suffix> [seconds]
// With --nudge the script resizes the PTY to 100 x 30 and back to 120 x 32
// when the statusline does not show after 10 seconds.
// With --start the script first starts the test session "bifrost-test-<suffix>".
// With --prompt "<text>" the script types the text after 3 seconds, and waits for the turn.
// The script attaches and reads the screen every 500 ms.
// The statusline counts as shown when a row below the prompt box has text
// that is not the mode footer, or when the screen has "% ctx" or "healthy".
// Without --prompt the script types nothing.
import * as L from './lib.ts'
const { TestPty, log, sleep, writeOut } = L

function statuslineRows(lines) {
  // The prompt box ends with the last full rule. The rows after it are the footer.
  let last = -1
  lines.forEach((l, i) => {
    if (/^─{20,}$/.test(l.trim())) last = i
  })
  if (last < 0) return []
  return lines
    .slice(last + 1)
    .filter(
      (l) =>
        l.trim() &&
        !/^\s*[⠀\s]*$/.test(l) &&
        !/auto mode on|for shortcuts|plan mode on|accept edits/.test(l)
    )
}

;(async () => {
  let id = process.argv[2]
  let seconds = Number(process.argv[3] || 120)
  if (id === '--start') {
    const r = await L.startBg(process.argv[3], 'Reply with the word READY.')
    log('start stdout:', JSON.stringify(r.stdout))
    id = r.id
    seconds = Number(process.argv[4] || 120)
  }
  if (!id) throw new Error('usage: watch-statusline.ts <short id> [seconds]')
  const e = await L.assertTestTarget({ id })
  const P = await TestPty.attach({ id })
  const R = { id, sessionStartedAt: e.startedAt, attachAt: P.t0, samples: [] }
  let shownAt = null
  let nudged = false
  const pi = process.argv.indexOf('--prompt')
  let promptText = pi > 0 ? process.argv[pi + 1] : null
  while (Date.now() - P.t0 < seconds * 1000 && !P.exitInfo) {
    const lines = await P.screenLines()
    const rows = statuslineRows(lines)
    const text = lines.join('\n')
    const shown = rows.length > 0 || /% ctx|healthy/.test(text)
    if (shown && shownAt === null) {
      shownAt = Date.now()
      R.firstRows = rows
      writeOut(`statusline-${id}-first.screen.txt`, text)
      log(
        `statusline shown ${shownAt - P.t0} ms after attach, ${shownAt - e.startedAt} ms after start:`,
        rows
      )
      break
    }
    if (promptText && Date.now() - P.t0 > 3000) {
      log(`type prompt: ${promptText}`)
      await P.typeLine(promptText)
      R.promptTurn = await L.waitTurn({ id }, { timeout: 90000 })
      R.promptTurnEndMs = Date.now() - P.t0
      log('prompt turn:', R.promptTurn.trace)
      promptText = null
      continue
    }
    if (process.argv.includes('--nudge') && !nudged && Date.now() - P.t0 > 10000) {
      nudged = true
      R.nudgeAtMs = Date.now() - P.t0
      log('no statusline after 10 s: resize to 100x30 and back to 120x32')
      P.resize(100, 30)
      await sleep(1500)
      P.resize(120, 32)
    }
    await sleep(500)
  }
  R.nudged = nudged
  R.shownAfterAttachMs = shownAt && shownAt - P.t0
  R.shownAfterStartMs = shownAt && shownAt - e.startedAt
  if (shownAt === null) log(`statusline not shown in ${seconds} s`)
  await P.save(`statusline-${id}`)
  P.lock('close')
  P.closeAttach('SIGHUP')
  await Promise.race([P.exited, sleep(5000)])
  writeOut(`statusline-${id}.json`, R)
  process.exit(0)
})().catch((err) => {
  console.error(err)
  process.exit(1)
})
