import { useEffect, useState } from 'react'
import { ageStepMs, formatAge } from './format'

// The age of one Activity cell. The cell has its own clock. It renders only when its text
// changes. The render reads the time, so a new "since" shows its age at once.
export function ActivityAge({ since }: { since: number }): React.ReactNode {
  const [, setTick] = useState(0)
  const now = Date.now()
  // No dependency list: each render sets a new timer for the next change of the text.
  useEffect(() => {
    const id = window.setTimeout(() => setTick(t => t + 1), ageStepMs(since, now))
    return () => window.clearTimeout(id)
  })
  return formatAge(since, now)
}
