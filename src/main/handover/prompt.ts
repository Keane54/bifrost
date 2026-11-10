// The prompts of the Hand over button (spec 8).
// The request prompt goes to the old session. The continue prompt is the first prompt of the new
// session. The rules come from the file of the bifrost-hand-over skill, so the skill and the
// button cannot differ (spec 7.5).
import { join } from 'node:path'
import { skillsSourceDir } from '../skills/skills-folder'

// Claude puts the note between these two lines. Each marker is on a line of its own.
export const NOTE_START = '[[BIFROST-HAND-OVER-NOTE-START]]'
export const NOTE_END = '[[BIFROST-HAND-OVER-NOTE-END]]'

// The first line of the request prompt. The reply reader finds the request by this line.
export function requestLine(requestId: string): string {
  return `Bifrost hand-over request ${requestId}`
}

// The prompt that asks the old session for the note. The rules text is in it unchanged.
// Each paragraph is on one line.
export function handOverPrompt(rules: string, requestId: string): string {
  const ask = [
    'Write a hand-over note for this session now.',
    'Use no tool, write no file, and change nothing.',
    'A new session continues the work from the note.',
    'The rules for the note follow.',
  ].join(' ')
  const form = [
    'Put the note in your reply between the two marker lines below.',
    'Put each marker on a line of its own, exactly as shown.',
    'Write nothing else between the markers.',
  ].join(' ')
  // The rules text keeps its own line breaks. A line break at its end is not added twice.
  const body = rules.endsWith('\n') ? rules.slice(0, -1) : rules
  return [
    requestLine(requestId),
    '',
    ask,
    '',
    body,
    '',
    form,
    '',
    NOTE_START,
    '<the note>',
    NOTE_END,
  ].join('\n')
}

// The first prompt of the new session. The note is last.
export function continuePrompt(note: string, notePath: string): string {
  const intro = [
    'Continue the work of an earlier session.',
    `Its hand-over note follows. The note is also saved at ${notePath}.`,
    'Read the note first, then continue with its next steps.',
    'Ask the user when something is not clear.',
  ].join(' ')
  return `${intro}\n\n${note}`
}

// The rules file in the skills folder of the app.
export function handOverRulesPath(appPath: string): string {
  return join(skillsSourceDir(appPath), 'skills', 'bifrost-hand-over', 'hand-over-rules.md')
}
