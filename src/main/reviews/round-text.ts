// The texts of a review round. The strings go to the user as given.

import { RECOMMENDATION_TEXT, type Recommendation } from '../../shared/reviews'
import type { RequestNotice } from './watcher'

export const REASON_TOO_LARGE =
  'This pull request is too big for a review session. Review it on GitHub.'
export const REASON_PR_CHANGED = 'The pull request changed while Bifrost got it ready. Try again.'
export const REASON_PR_CLOSED = "This pull request is closed, so Bifrost didn't review it."
export const REASON_NO_RESULT =
  'The review session ended without a result. Nothing was posted. Try again.'
export const REASON_STOPPED = 'You stopped the review. Nothing was posted.'
export const REASON_TIMEOUT =
  'The review took more than 30 minutes, so Bifrost stopped it. Nothing was posted.'
export const REASON_OTHER_COMMIT =
  'You have a draft review on an older commit of this pull request. ' +
  'Submit or delete it on GitHub, then try again.'
export const REASON_NOT_PENDING =
  "GitHub didn't keep the review as a draft. Check the pull request on GitHub now."
export const REASON_CLOSED_WHILE_POSTING =
  'Bifrost closed while it saved the draft review. Check the pull request on GitHub.'

export const reasonBadResult = (why: string): string =>
  `The review session wrote a result Bifrost couldn't use (${why}). Nothing was posted. Try again.`

export const reasonPostFailed = (message: string): string =>
  `GitHub didn't accept the draft review: ${message} Nothing was posted.`

export const reasonPartlyAdded = (added: number, total: number, message: string): string =>
  `GitHub stopped after ${added} of ${total} comments: ${message} ` +
  'Check your draft review on GitHub.'

interface NoticePr {
  repo: string
  number: number
}

export function draftNotice(pr: NoticePr, value: Recommendation): RequestNotice {
  return {
    body: `Your draft review is ready. Claude suggests: ${RECOMMENDATION_TEXT[value]}.`,
    title: `${pr.repo} #${pr.number}`,
  }
}

export function reviewedNotice(pr: NoticePr): RequestNotice {
  return {
    body: 'Claude found nothing to flag and suggests you approve. Nothing was posted.',
    title: `${pr.repo} #${pr.number}`,
  }
}

// repo is owner/repo.
export function trustNotice(repo: string): RequestNotice {
  return {
    body: `Trust ${repo} in Bifrost so Claude can work on its pull requests.`,
    title: 'Trust needed',
  }
}
