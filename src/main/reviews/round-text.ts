// The texts of a review round. The strings go to the user as given.

import { RECOMMENDATION_TEXT, type Recommendation } from '../../shared/reviews'
import type { UnsafeRule } from './repo-store'
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

// The row shows this text. The Event log gets the raw gh line.
export const REASON_PR_READ_FAILED =
  "Bifrost couldn't load this pull request from GitHub, so nothing was posted. Try again. " +
  'The Event log has the details.'

// Ruling P6: a new request round first sends the waiting updates of an earlier round. When the
// read of the PR after them fails, those updates are on GitHub, so the text must not say that
// nothing was posted.
export const REASON_READ_AFTER_POSTS =
  "Bifrost sent the waiting updates, then couldn't load this pull request from GitHub. " +
  'Try again. The Event log has the details.'

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

// The texts of the fix commit and the push of a request round. Bifrost refuses the push before
// any network call.
export const REASON_PUSH_TARGET = "Bifrost won't push to this branch, so it posted nothing."
export const REASON_PUSH_CONFLICT =
  "Someone pushed to this branch, and Claude's fix doesn't merge cleanly. " +
  'Bifrost posted the other replies. Choose Try again to let Claude fix it on the new code.'
export const REASON_PUSH_MOVED =
  'The branch kept changing while Bifrost pushed. Bifrost posted the other replies. ' +
  'Choose Try again.'

// The push went to GitHub, but the branch was gone. A push cannot delete a branch.
export const REASON_PUSH_NEW_BRANCH =
  'The branch was deleted on GitHub while Bifrost pushed, so the push made it again. ' +
  "Delete it on GitHub if you don't need it."

export const reasonPushFailed = (line: string): string => `GitHub didn't take the push: ${line}`
// A git command of the push or of the fix commit failed. The row gets this text after
// reasonPushFailed or reasonCommitFailed. The Event log gets the line of git.
export const REASON_PUSH_GIT_FAILED = 'git stopped with an error. The Event log has the details.'

// The texts of a fix commit that Bifrost does not send through GitHub with signed commits on.
// GitHub makes each file of that commit a plain file (ruling S22), and takes at most 4 MB of
// files (ruling S23). Bifrost refuses before any write, and Try again starts a new round.
export const REASON_SIGNED_EXECUTABLE =
  "Claude's fix changes a file that must stay executable, and GitHub can't keep that in a " +
  'commit it signs. Nothing was posted. Turn off Sign commits through GitHub for this fix ' +
  'and choose Try again, or make the change yourself.'
export const REASON_SIGNED_LINK =
  "Claude's fix changes a link or a submodule, and GitHub can't keep that in a commit it " +
  'signs. Nothing was posted. Turn off Sign commits through GitHub for this fix and choose ' +
  'Try again, or make the change yourself.'
export const REASON_SIGNED_TOO_LARGE =
  "Claude's fix is over 4 MB, which is too large for a commit that GitHub signs. Nothing " +
  'was posted. Turn off Sign commits through GitHub for this fix and choose Try again, ' +
  'or make the change yourself.'

export const reasonCommitFailed = (line: string): string =>
  `Bifrost couldn't commit Claude's fix: ${line}`

// A git filter, for example Git LFS, can change the file that goes into the commit. Bifrost could
// then push an LFS pointer with no object, because no hook of a filter runs.
export const REASON_FILTER_CHANGE =
  'Claude changed a file that Git LFS or another git filter handles. ' +
  "Bifrost can't push that safely, so nothing was posted. Make this change yourself."

const UNSAFE_CHANGE: Record<Exclude<UnsafeRule, 'filter'>, string> = {
  claude: 'a file in a .claude folder',
  large: 'a file over 1 MB',
  link: 'a file link',
  outside: 'a file outside its folder',
  submodule: 'a submodule',
  unchanged: "a file list that doesn't match its changes",
  workflow: 'a GitHub workflow or action file',
}

export const reasonUnsafeChange = (rule: UnsafeRule): string =>
  rule === 'filter'
    ? REASON_FILTER_CHANGE
    : `Claude changed ${UNSAFE_CHANGE[rule]}, which Bifrost doesn't push. Nothing was posted.`

// The texts of the GitHub writes of a request round. Bifrost refuses these PRs before any write.
export const REASON_FIX_PR_CLOSED = 'This pull request was closed, so Bifrost stopped posting.'
export const REASON_NOT_YOURS = "This pull request isn't yours, so Bifrost stopped."
export const REASON_FORK =
  "This pull request comes from a fork. Bifrost can't push there, so Claude leaves its comments " +
  'to you.'
export const REASON_OWN_PENDING =
  "You have a draft review on this pull request, and Bifrost's replies would go into it. " +
  'Submit or delete the draft on GitHub, then choose Try again.'
export const REASON_REPLY_PENDING =
  'A reply went into a draft review on GitHub. Submit or delete the draft, then choose Try again.'

// The checks of the user settings of Claude Code before a request session starts. The user
// settings load in the session, so Bifrost starts no session when they change the sandbox. A
// text names no value of the file.
export const REASON_USER_SANDBOX =
  "Your Claude Code sandbox settings change the network or file rules, so Bifrost can't keep " +
  'this request session safe. Remove them from ~/.claude/settings.json to let Bifrost fix ' +
  'comments.'
export const REASON_USER_SANDBOX_OFF =
  "Your Claude Code settings turn the sandbox off, so Bifrost can't keep this request session " +
  'safe. Remove sandbox.enabled from ~/.claude/settings.json to let Bifrost fix comments.'
export const REASON_USER_FOLDERS =
  "Your Claude Code settings give Claude more folders to work in, so Bifrost can't keep this " +
  'request session safe. Remove additionalDirectories from ~/.claude/settings.json to let ' +
  'Bifrost fix comments.'
export const REASON_USER_SETTINGS_UNREADABLE =
  "Bifrost couldn't read ~/.claude/settings.json, so it can't check that this request session " +
  'is safe. Fix the file to let Bifrost fix comments.'

// A cut context cannot show a sent reply or a deleted thread, so Bifrost writes nothing.
export const REASON_TOO_MANY_COMMENTS =
  'This pull request has too many comments for Bifrost to check, so nothing was posted. ' +
  'Reply to them on GitHub.'

// The reasons of a failed write. They come after the text of reasonPostsStopped, so they do not
// name GitHub again. GitHub can have saved a write that did not answer in time. The next run
// checks GitHub before it sends that write again.
export const REASON_WRITE_TIMEOUT = 'it took too long to answer.'
export const REASON_WRITE_UNREADABLE = "Bifrost couldn't read the answer."
export const REASON_NOT_RESOLVED = "the thread didn't get resolved."
// gh or GitHub gave an error text for a write. The Event log gets that text, because it can be
// long or technical.
export const REASON_WRITE_FAILED = 'it sent back an error. The Event log has the details.'
// A read of the PR failed while Bifrost posts. Updates of the outbox can be on GitHub already,
// so the text does not say that nothing was posted. The Event log gets the error text.
export const REASON_POSTS_READ_FAILED =
  "Bifrost couldn't load the pull request. The Event log has the details."
// GitHub refused the signed commit with a text that quotes a file of the fix. That text never
// shows.
export const REASON_FILES_REFUSED = 'it refused the files of the fix.'

export const reasonPostsStopped = (done: number, total: number, message: string): string =>
  `GitHub stopped after ${done} of ${total} updates: ${message} Choose Try again to send the rest.`

// The user chose Stop session while Bifrost posted. Bifrost sends no more updates.
export const reasonUserStoppedPosts = (done: number, total: number): string =>
  `You stopped Bifrost after ${done} of ${total} updates. Choose Try again to send the rest.`

// Remove all clones kept an outbox whose fix is on GitHub already. Try again needs no clone.
export const REASON_REPLIES_WAITING =
  'Bifrost removed its copies of your repositories before it posted every reply. ' +
  'Choose Try again to post the rest.'

// The texts of a request round. A failed round posts nothing, and the row shows the text.
export const REASON_FIX_STOPPED =
  'You stopped Claude, so Bifrost posted nothing. Choose Try again to start over.'
export const REASON_FIX_TIMEOUT =
  'Claude took more than 30 minutes, so Bifrost stopped it and posted nothing.'
export const REASON_FIX_NO_RESULT = 'Claude finished without a result, so Bifrost posted nothing.'
export const reasonFixBadResult = (why: string): string =>
  `Claude wrote a result Bifrost couldn't use (${why}), so Bifrost posted nothing.`
// A request session must never ask. Bifrost stops a session that shows a prompt.
export const REASON_FIX_BLOCKED =
  'Claude got stuck waiting for an answer, so Bifrost stopped it and posted nothing.'

// The fixed texts for an error of Node, git or claude in a request round. The log gets the error.
// The row never shows the error, because it can hold a path.
export const REASON_FIX_PREPARE_FAILED =
  "Bifrost couldn't get this pull request ready for Claude, so it posted nothing. " +
  'Choose Try again.'
export const REASON_FIX_START_FAILED =
  "Bifrost couldn't start Claude's session, so it posted nothing. Choose Try again."
// GitHub can have saved a write before the error. So this text does not say that nothing was
// posted.
export const REASON_FIX_END_FAILED =
  "Bifrost couldn't finish this round. Check the pull request on GitHub, then choose Try again."
// The place of a question about a comment that is gone from GitHub, for the Answer panel.
export const WHERE_DELETED = 'A deleted comment'
// The commit failed with an error that can hold a path.
export const REASON_COMMIT_ERROR = reasonCommitFailed(
  'an error stopped it. The log has the details.',
)

// The texts of the Approve button of the To review tab (user decision, 2026-11-13). The row shows
// the text of a click that did not approve. Bifrost made no write for the texts of the fresh check.
export const REASON_APPROVE_CLOSED =
  "This pull request is closed or merged, so Bifrost didn't approve it."
export const REASON_APPROVE_OWN = "You can't approve your own pull request."
export const REASON_APPROVE_NOT_SUGGESTED =
  "Claude doesn't suggest Approve for this pull request any more, so Bifrost didn't approve it."
export const REASON_APPROVE_CHANGED =
  "This pull request changed after Claude's review, so Bifrost didn't approve it. " +
  'It needs a new review.'
export const REASON_APPROVE_DONE = 'You already approved this commit on GitHub.'
// The CI rules (user decision, 2026-11-13). The fresh check refuses before any write.
// A queued review that CI stopped before its turn. The row shows it as the note of the PR.
export const REASON_CI_DROPPED = "CI started failing, so Bifrost didn't review this pull request."
export const REASON_APPROVE_CI_FAILING =
  "CI is failing on this pull request, so Bifrost didn't approve it."
export const REASON_APPROVE_CI_RUNNING = 'CI is still running. Approve when it has passed.'
export const REASON_APPROVE_PENDING =
  'You have a draft review on this pull request. Submit or delete it on GitHub first, ' +
  'then try again.'
export const REASON_APPROVE_NO_DRAFT =
  "Bifrost couldn't find Claude's draft review on GitHub, so it didn't approve. " +
  'The draft may have been submitted or deleted.'
export const REASON_APPROVE_DRAFT_COMMIT =
  "Claude's draft review is on another commit, so Bifrost didn't submit it."
// The guard of the write refused it. Bifrost sent nothing.
export const REASON_APPROVE_REFUSED =
  "Bifrost stopped this approval because it didn't match Claude's review. Nothing was posted."
// GitHub can have saved the approval. So these texts do not ask the user to try again.
export const REASON_APPROVE_UNKNOWN =
  "Bifrost couldn't tell if GitHub saved your approval. Click Refresh to check."
export const REASON_APPROVE_NOT_APPROVED =
  'GitHub saved the review, but not as an approval. Check the pull request on GitHub.'
// GitHub refused the approval. The Event log gets the raw text.
export const REASON_APPROVE_FAILED =
  "GitHub didn't accept the approval. The Event log has the details."
export const reasonApproveFailed = (message: string): string =>
  `Bifrost couldn't approve this pull request. ${message}`
// An error of Node before the write. The log gets the error.
export const REASON_APPROVE_ERROR = "Bifrost couldn't approve this pull request. Please try again."

// The texts of the Review panel (user decision, 2026-11-13). The panel and the row show them.
// Bifrost wrote nothing for the texts of the fresh check and of the checks of the edits.
export const REASON_DRAFT_CLOSED =
  "This pull request is closed or merged, so Bifrost didn't change the draft."
export const REASON_DRAFT_OWN = "This is your own pull request, so Bifrost didn't change the draft."
export const REASON_DRAFT_GONE =
  "Bifrost couldn't find Claude's draft review on GitHub, so it didn't change anything. " +
  'The draft may have been submitted or deleted.'
export const REASON_DRAFT_COMMIT =
  "Claude's draft review is on another commit, so Bifrost didn't change it."
export const REASON_DRAFT_CHANGED =
  "This pull request changed after Claude's review, so Bifrost didn't send or approve it. " +
  'You can still discard the draft.'
export const REASON_DRAFT_TOO_MANY =
  'This draft has more comments than Bifrost can show. Please finish it on GitHub.'
export const REASON_DRAFT_EDITED =
  'The draft changed on GitHub after you opened it, so Bifrost sent nothing. ' +
  'Close this panel and open it again.'
export const REASON_DRAFT_EMPTY = 'Add a summary or keep a comment, then send the review.'
export const REASON_DRAFT_NEEDS_SUMMARY = 'Add a summary to request changes.'
export const REASON_DRAFT_BLANK = 'One comment has no text. Write something, or remove the comment.'
// The guard of the writes refused one. Bifrost sent nothing more.
export const REASON_DRAFT_REFUSED =
  "Bifrost stopped this because it didn't match Claude's draft. Nothing more was sent."
// A change of the summary or of a comment did not work. The review is still a draft.
export const REASON_DRAFT_EDIT_FAILED =
  "GitHub didn't take all of your changes, so the review is still a draft. Your edits are " +
  'still here, so you can send it again. The Event log has the details.'
export const REASON_DRAFT_EDIT_UNKNOWN =
  "Bifrost couldn't tell if GitHub saved all of your changes. The review is still a draft, " +
  'and your edits are still here, so you can send it again.'
export const REASON_DRAFT_NOT_PENDING =
  "Claude's review isn't a draft on GitHub any more. Check the pull request on GitHub."
export const REASON_SEND_FAILED =
  "GitHub didn't send the review, so it's still a draft. Your edits are still here, so you " +
  'can try again. The Event log has the details.'
// GitHub can have sent the review. So these texts do not ask the user to try again.
export const REASON_SEND_UNKNOWN =
  "Bifrost couldn't tell if GitHub sent your review. Click Refresh to check."
export const REASON_SEND_NOT_AS_SENT =
  'GitHub saved the review, but not as you sent it. Check the pull request on GitHub.'
export const REASON_DISCARD_FAILED =
  "GitHub didn't delete the draft. The Event log has the details."
export const REASON_DISCARD_UNKNOWN =
  "Bifrost couldn't tell if GitHub deleted the draft. Click Refresh to check."
// Approve instead deleted the draft, and then the approval did not work.
export const REASON_INSTEAD_FAILED =
  "The draft is deleted, but the approval didn't go through. Click Approve on the row to " +
  'try again.'
export const REASON_INSTEAD_UNKNOWN =
  "The draft is deleted, but Bifrost couldn't tell if GitHub saved your approval. " +
  'Click Refresh to check.'
// An error of Node before a write. The log gets the error.
export const REASON_DRAFT_ERROR = "Bifrost couldn't finish that. Please try again."
export const reasonDraftFailed = (message: string): string =>
  `Bifrost couldn't change the draft. ${message}`

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

// One notification when a request round has new questions for the user.
export function needsYouNotice(pr: NoticePr, n: number): RequestNotice {
  const comments = n === 1 ? '1 comment' : `${n} comments`
  return { body: `Claude needs your answer on ${comments}.`, title: `${pr.repo} #${pr.number}` }
}
