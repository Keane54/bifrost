import type { SessionRow } from '../../shared/types'

// Decide if the main process may open a PTY with these args.
// Allowed: "attach <short id>" for one owned session that is not parked. Nothing else.
// The renderer sends the args, so check the type of each value.
export function canAttach(rows: SessionRow[], args: string[]): boolean {
  if (!Array.isArray(args) || args.length !== 2 || args[0] !== 'attach') return false
  const target = args[1]
  if (typeof target !== 'string' || target === '') return false
  const matches = rows.filter(row => row.shortId === target)
  return matches.length === 1 && matches[0].kind === 'owned' && matches[0].state !== 'parked'
}
