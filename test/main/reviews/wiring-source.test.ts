// A source test of the review wiring in ipc.ts. It reads the file as text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, test } from 'vitest'

const code = readFileSync(join(__dirname, '../../../src/main/ipc.ts'), 'utf8')

// The text of one ipcMain.handle call, from its channel to the next handle call.
function handler(channel: string): string {
  const start = code.indexOf(`ipcMain.handle('${channel}'`)
  expect(start, channel).toBeGreaterThan(-1)
  const next = code.indexOf('ipcMain.handle(', start + 10)
  return code.slice(start, next === -1 ? undefined : next)
}

const NEW_CHANNELS = [
  'reviews:review',
  'reviews:cancel',
  'reviews:stop-session',
  'reviews:trust-open',
  'reviews:trust-write',
  'reviews:trust-resize',
  'reviews:trust-close',
  'reviews:remove-clones',
  'reviews:handle',
  'reviews:retry',
  'reviews:answer',
]

describe('the review wiring in ipc.ts', () => {
  test.each(NEW_CHANNELS)('%s goes through fromPage', channel => {
    expect(handler(channel)).toMatch(/fromPage\(/)
  })

  test('reviews:review checks the PR key', () => {
    expect(handler('reviews:review')).toMatch(/checkPrKey\(/)
  })

  test('the request channels use the PR key of the right tab', () => {
    for (const channel of ['reviews:handle', 'reviews:retry', 'reviews:answer']) {
      expect(handler(channel), channel).toMatch(/mineKey\(/)
    }
    for (const channel of ['reviews:cancel', 'reviews:stop-session']) {
      expect(handler(channel), channel).toMatch(/rowKey\(/)
    }
    expect(handler('reviews:review')).toMatch(/toReviewKey\(/)
  })

  test('reviews:handle takes only the fixed words', () => {
    const text = handler('reviews:handle')
    expect(text).toMatch(/'all'/)
    expect(text).toMatch(/'copilot'/)
    expect(text).toMatch(/REFUSED_NOT_HANDLEABLE/)
  })

  test('reviews:answer checks the count, the item ID and the length', () => {
    expect(handler('reviews:answer')).toMatch(/checkAnswers\(answers\)/)
    const check = code.slice(code.indexOf('function checkAnswers'))
    const body = check.slice(0, check.indexOf('\n}\n'))
    expect(body).toMatch(/ITEM_ID\.test\(/)
    expect(body).toMatch(/text\.length > MAX_ANSWER/)
    expect(body).toMatch(/MAX_ANSWERS/)
    expect(body).toMatch(/REFUSED_BAD_ANSWER/)
    expect(body).toMatch(/Object\.keys\(/)
  })

  test('a test home gives git a user name and an email', () => {
    expect(code).toMatch(/extraConfig: home === null \? \[\] : TEST_GIT_IDENTITY/)
    expect(code).toMatch(/user\.name=Bifrost Test/)
    expect(code).toMatch(/user\.email=bifrost-test@example\.invalid/)
  })

  test('the reviews-autofix effect calls the runner and then rebuilds the watcher', () => {
    const re = /case 'reviews-autofix':[\s\S]*?autoFixChanged\(effect\.on\)[\s\S]*?rebuild\(\)/
    expect(code).toMatch(re)
  })

  test('the turn-on saves fixFrom before the runner and the watcher start', () => {
    const on = code.slice(code.indexOf("case 'reviews':"), code.indexOf("case 'reviews-view':"))
    const saved = on.indexOf('watchTurnedOn()')
    expect(saved).toBeGreaterThan(-1)
    expect(on.indexOf('reviewRunner?.start()')).toBeGreaterThan(saved)
    expect(on.indexOf('reviewsWatcher?.start()')).toBeGreaterThan(saved)
  })

  test('the watcher gets the Claude state of the runner', () => {
    expect(code).toMatch(/mine: key => reviewRunner\?\.mine\(key\)/)
  })

  test('reviews:trust-open checks the repository key', () => {
    expect(handler('reviews:trust-open')).toMatch(/REPO_KEY\.test\(/)
    expect(handler('reviews:trust-open')).toMatch(/REFUSED_UNKNOWN_REPO/)
  })

  test('only remove-clones works while Watch GitHub is off', () => {
    for (const channel of NEW_CHANNELS.filter(c => c !== 'reviews:remove-clones')) {
      expect(handler(channel), channel).toMatch(/whileOn\(/)
    }
    expect(handler('reviews:remove-clones')).not.toMatch(/whileOn\(/)
  })

  test('the trust output goes to the page and the runner is never settled', () => {
    expect(code).toMatch(/send\('reviews:trust-data'/)
    expect(code).toMatch(/send\('reviews:trust-end'/)
    expect(code).not.toMatch(/\.settled\(/)
  })

  test('the end of the trust step and a closed trust panel each allow one start', () => {
    expect(code).toMatch(/onEnd: end => \{[\s\S]*?runner\.trustChanged\(end\.repo\)/)
    const close = handler('reviews:trust-close')
    const current = close.indexOf('trustWindow?.current()')
    expect(current).toBeGreaterThan(-1)
    expect(close.indexOf('trustWindow?.close()')).toBeGreaterThan(current)
    expect(close).toMatch(/reviewRunner\?\.trustChanged\(repo\)/)
  })

  test('stopRegistry stops the runner and closes the trust window', () => {
    const stop = code.slice(code.indexOf('export function stopRegistry'))
    expect(stop).toMatch(/reviewRunner\?\.stop\(\)/)
    expect(stop).toMatch(/trustWindow\?\.close\(\)/)
  })

  test('the PR channels and remove-clones hide a raw error', () => {
    for (const channel of [
      'reviews:review',
      'reviews:cancel',
      'reviews:stop-session',
      'reviews:remove-clones',
    ]) {
      expect(handler(channel), channel).toMatch(/friendlyFailure\(/)
    }
  })

  test('the end of a page closes the trust terminal before the PTYs', () => {
    expect(code).toMatch(
      /new PageScope\(\(\) => \{\s*trustWindow\?\.close\(\)\s*liveManager\?\.closeAll\(\)\s*\}\)/,
    )
  })

  test('a service callback of the runner cannot throw into the registry', () => {
    expect(code).toMatch(/service\.onUpdate\(rows => \{\s*try \{\s*runner\.onRows\(rows\)/)
  })

  test('the runner gets the review job, the request job with both pushers, and minePr', () => {
    expect(code).toMatch(/createFixPusher\(\{ git: repoGit, remoteBase: remoteBase\(/)
    expect(code).toMatch(/createSignedPusher\(\{\s*gh,\s*git: repoGit,\s*remoteBase: /)
    expect(code).toMatch(
      /jobs: \[createReviewJob\(\), createRequestJob\(\{ pusher, signedPusher \}\)\]/,
    )
    expect(code).toMatch(/minePr: key => watcher\.minePr\(key\)/)
  })

  test('the runner can turn off the automatic setting at the first poll of R3', () => {
    expect(code).toMatch(
      /turnOffAutoFix: async \(\) => \{\s*await settings\.update\(\{ reviewsAutoFix: false \}\)/,
    )
  })

  test('the branch read skips the reviews folder, where a PR session can write', () => {
    expect(code).toMatch(/createBranchReader\(execFile, \{ skipRoot: reposRoot\(bifrostHome\) \}\)/)
    expect(code).toMatch(/readBranch: cwd => branchReader\.read\(cwd\)/)
  })

  test('Reviews run with no runner when the registry service fails', () => {
    expect(code).toMatch(/parts\.service\.catch\(/)
  })
})
