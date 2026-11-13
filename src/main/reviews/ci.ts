// The CI state of a PR (user decision, 2026-11-13). GitHub gives one combined result for the
// latest commit of a PR: statusCheckRollup. A failing PR gets no review and no approval. A PR with
// running CI gets a review, but no approval until CI has passed.

import { isRecord } from '../../shared/plain-object'

// failing: FAILURE or ERROR, also for an optional check. running: PENDING or EXPECTED, or a
// rollup of another commit than the head. passed: SUCCESS. null: the PR has no CI.
export type CiState = 'failing' | 'running' | 'passed' | null

const STATES: Readonly<Record<string, CiState>> = {
  ERROR: 'failing',
  EXPECTED: 'running',
  FAILURE: 'failing',
  PENDING: 'running',
  SUCCESS: 'passed',
}

// The CI state from the latest commit node of the PR ({ oid, statusCheckRollup: { state } }) and
// the head of the PR. A rollup of another commit says nothing about the head, so it counts as
// running. A missing rollup or an unknown state gives null (no CI), as GitHub does for a PR with
// no checks.
export function ciOf(commit: unknown, head: string): CiState {
  if (!isRecord(commit)) return null
  const rollup = commit.statusCheckRollup
  if (!isRecord(rollup) || typeof rollup.state !== 'string') return null
  const state = Object.hasOwn(STATES, rollup.state) ? (STATES[rollup.state] ?? null) : null
  if (state === null) return null
  return head !== '' && commit.oid !== head ? 'running' : state
}
