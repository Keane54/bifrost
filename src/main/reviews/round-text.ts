// The texts of a review round. The strings go to the user as given.

import { RECOMMENDATION_TEXT, type Recommendation } from '../../shared/reviews'
import { count, MAX_REVIEW_BODY } from './result-file'
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
// A review session must never ask. Bifrost stops a session that shows a prompt.
export const REASON_BLOCKED =
  'The review session stopped to ask for something, so Bifrost stopped it. Nothing was posted.'
// A new round on the draft review of Bifrost would add each comment a second time.
export const REASON_OWN_DRAFT =
  'Your draft review from Bifrost is still on GitHub for this commit. ' +
  'Submit or delete it there, then try again. Nothing was posted.'

// The fixed texts for an error of Node, git or claude in a round. The log gets the error. The
// row never shows the error, because it can hold a path.
export const REASON_PREPARE_FAILED =
  "Bifrost couldn't get this pull request ready for a review. Nothing was posted. Try again."
export const REASON_START_FAILED =
  "Bifrost couldn't start the review session. Nothing was posted. Try again."
// GitHub can have saved the draft review before the error. So this text does not say that
// nothing was posted.
export const REASON_END_FAILED =
  "Bifrost couldn't finish the review. Check the pull request on GitHub."

// Bifrost made no call for these three texts.
export const REASON_DRAFT_TOO_LONG =
  "Your draft review text and Claude's summary together are longer than GitHub allows " +
  `(${count(MAX_REVIEW_BODY)} characters). Nothing was posted.`
export const REASON_SUMMARY_TOO_LONG =
  `Claude's summary is longer than GitHub allows (${count(MAX_REVIEW_BODY)} characters). ` +
  'Nothing was posted.'
export const REASON_BAD_PR =
  "Bifrost couldn't use the owner, repository or number of this pull request. " +
  'Nothing was posted.'
// GitHub can have saved the write. So these texts do not say that nothing was posted, and they do
// not ask the user to try again.
export const REASON_POST_TIMEOUT =
  "GitHub didn't answer in time, so Bifrost can't tell if your draft review was saved. " +
  'Check the pull request on GitHub.'
export const REASON_POST_UNREADABLE =
  "Bifrost couldn't read the answer from GitHub, so it can't tell if your draft review was " +
  'saved. Check the pull request on GitHub.'
export const reasonPostUnknown = (message: string): string =>
  `Bifrost can't tell if your draft review was saved: ${message} Check the pull request on GitHub.`

export const reasonBadResult = (why: string): string =>
  `The review session wrote a result Bifrost couldn't use (${why}). Nothing was posted. Try again.`

export const reasonPostFailed = (message: string): string =>
  `GitHub didn't accept the draft review: ${message} Nothing was posted.`

export const reasonPartlyAdded = (added: number, total: number, message: string): string =>
  `GitHub stopped after ${added} of ${total} comments: ${message} ` +
  'Check your draft review on GitHub.'

// All the comments are in the draft review. Only the summary is not.
export const reasonSummaryFailed = (message: string): string =>
  "Bifrost added the comments to your draft review, but GitHub didn't add the summary: " +
  `${message} Check your draft review on GitHub.`

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
