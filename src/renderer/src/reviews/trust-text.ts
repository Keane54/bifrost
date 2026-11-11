// The text of one line of the Trust needed strip.
export function waitingText(waiting: number): string {
  return waiting === 1 ? '1 pull request waiting' : `${waiting} pull requests waiting`
}
