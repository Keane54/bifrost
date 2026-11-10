// This script prints the release summary for the release notes.
// The person who starts the Release workflow must type a summary (user decision, 2026-11-10). The
// workflow gives it to semantic-release in the RELEASE_SUMMARY env variable. The generateNotesCmd
// of the exec plugin (.releaserc.json) runs this script. semantic-release puts the output before
// the notes of the release-notes-generator plugin.
// The first step of the workflow checks the same rules. This script checks them again, so a
// release never gets an empty summary or a summary that is too long.

// The maximum number of characters in a summary.
export const SUMMARY_MAX = 600

export type SummaryResult = { ok: true; text: string } | { ok: false; message: string }

// The release notes use "#" for their headings. GitHub shows a summary line that starts with "#"
// as a heading, and the app reads the summary only up to the first heading. So a summary line
// must not start with "#", also after spaces.
const HEADING_LINE = /^\s*#/m

// The text to print for the value of RELEASE_SUMMARY: the trimmed summary and a blank line. An
// empty summary, a summary that is too long, and a summary with a line that starts with "#" give
// an error message. The count of characters uses code points, so each emoji counts one time.
export function releaseSummary(value: string | undefined): SummaryResult {
  const summary = (value ?? '').trim()
  if (summary === '') {
    return {
      message: 'The release summary is empty. Type a short summary of the release.',
      ok: false,
    }
  }
  const count = [...summary].length
  if (count > SUMMARY_MAX) {
    const limit = `The limit is ${SUMMARY_MAX}. Write a shorter summary.`
    return { message: `The release summary has ${count} characters. ${limit}`, ok: false }
  }
  if (HEADING_LINE.test(summary)) {
    return {
      message:
        'A line of the release summary starts with "#". Remove the "#", because the release ' +
        'notes use "#" for their headings.',
      ok: false,
    }
  }
  return { ok: true, text: `${summary}\n\n` }
}

if (import.meta.main) {
  const result = releaseSummary(process.env.RELEASE_SUMMARY)
  if (result.ok) {
    process.stdout.write(result.text)
  } else {
    console.error(result.message)
    process.exitCode = 1
  }
}
