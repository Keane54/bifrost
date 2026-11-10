// This script checks the frontmatter rules of the Bifrost skills (resources/bifrost-skills).
// The CI job "checks" runs it with "pnpm check:skills". A failed rule exits with code 1.

import { checkPlugin } from '../src/shared/skill-check.ts'
import { readPluginSnapshot } from './skills/snapshot.ts'

const failures = checkPlugin(readPluginSnapshot('resources/bifrost-skills'))
if (failures.length === 0) {
  console.log('PASS: the Bifrost skills follow the rules')
} else {
  for (const failure of failures) console.log(`FAIL: ${failure}`)
  process.exit(1)
}
