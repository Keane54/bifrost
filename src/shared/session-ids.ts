// The session IDs of a row (spec 6.1). The row ID (sessionId) never changes. The current ID is
// the conversation that the row shows now. A /clear changes it.
import type { SessionRow } from './types'

// The refusal when Bifrost does not know the resume ID of a background row yet.
export const REFUSED_NO_RESUME_ID = 'refused: the ID that resumes this session is not known yet'

// The session ID of the conversation that a row shows now.
export function currentIdOf(row: Pick<SessionRow, 'currentId' | 'sessionId'>): string {
  return row.currentId ?? row.sessionId
}

// The ID that `claude --resume` needs to continue the session of a row (ruling of 2026-11-06).
// For a background (owned) row it is the resume ID: the original session ID of the job. A resume
// by another ID starts a second job (section 4). It is undefined when Bifrost does not know it
// yet. For an interactive (external) row it is the current ID.
export function continueIdOf(
  row: Pick<SessionRow, 'currentId' | 'kind' | 'resumeId' | 'sessionId'>,
): string | undefined {
  return row.kind === 'owned' ? row.resumeId : currentIdOf(row)
}
