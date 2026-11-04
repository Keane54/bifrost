// Check that assertTestTarget refuses the wrong targets.
// This script only reads "claude agents --json". It sends nothing to a session.
// It tries each non-test entry, the reserved session and a missing id.
// Each try must throw a SafetyError.
import { listAgents, assertTestTarget, SafetyError, log } from './lib.ts'

async function expectRefusal(target) {
  try {
    await assertTestTarget(target)
    log(`FAIL: accepted ${JSON.stringify(target)}`)
    return false
  } catch (e) {
    if (!(e instanceof SafetyError)) throw e
    log(`ok: refused ${JSON.stringify(target)}: ${e.message}`)
    return true
  }
}

;(async () => {
  const list = await listAgents()
  let ok = true
  for (const e of list) {
    if (!String(e.name).startsWith('bifrost-test-')) {
      ok = (await expectRefusal({ pid: e.pid })) && ok
      ok = (await expectRefusal({ sessionId: e.sessionId })) && ok
    }
  }
  ok = (await expectRefusal({ name: 'bifrost-test-idle' })) && ok
  ok = (await expectRefusal({ id: '1db8945b' })) && ok
  ok = (await expectRefusal({ id: 'ffffffff' })) && ok
  log(ok ? 'safety check passed' : 'safety check FAILED')
  process.exit(ok ? 0 : 1)
})()
