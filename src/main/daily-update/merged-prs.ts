// The merged PRs of the user since a time, from the GitHub CLI (gh).

import { type Gh, ghFailure } from '../reviews/gh'
import { cutText } from '../reviews/review-input'

export const MAX_PR_BODY = 2000

export interface DailyPr {
  repo: string
  number: number
  title: string
  url: string
  mergedAt: string
  body: string
}

export function mergedPrsArgs(sinceIso: string): string[] {
  return [
    'search',
    'prs',
    '--author=@me',
    `--merged-at=>=${sinceIso}`,
    '--limit',
    '100',
    '--json',
    'number,title,url,repository,closedAt,body',
  ]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// Give null for an item with a missing field or a field of the wrong type. For a merged PR,
// closedAt is the merge time. A PR with no description has a null body.
function toPr(raw: unknown): DailyPr | null {
  if (!isRecord(raw)) return null
  const { number, title, url, closedAt, body, repository } = raw
  if (typeof number !== 'number' || !Number.isSafeInteger(number)) return null
  if (typeof title !== 'string' || typeof url !== 'string' || typeof closedAt !== 'string') {
    return null
  }
  if (body !== null && body !== undefined && typeof body !== 'string') return null
  if (!isRecord(repository)) return null
  const repo = repository.nameWithOwner
  if (typeof repo !== 'string' || repo === '') return null
  return {
    body: cutText(body ?? '', MAX_PR_BODY),
    mergedAt: closedAt,
    number,
    repo,
    title,
    url,
  }
}

export async function fetchMergedPrs(
  gh: Gh,
  sinceIso: string,
): Promise<{ ok: true; prs: DailyPr[] } | { ok: false; reason: string }> {
  const result = await gh.run(mergedPrsArgs(sinceIso))
  const failure = ghFailure(result)
  if (failure) return { ok: false, reason: failure.message }
  let data: unknown
  try {
    data = JSON.parse(result.stdout)
  } catch {
    return { ok: false, reason: 'gh gave output that is not JSON' }
  }
  if (!Array.isArray(data)) return { ok: false, reason: 'gh gave output that is not a list' }
  return { ok: true, prs: data.flatMap(item => toPr(item) ?? []) }
}
