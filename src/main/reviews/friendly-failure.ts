// A call of the page must not give a raw error to the page. A raw error can hold a path.

const REFUSAL = 'refused: '

// Run fn. A refusal of Bifrost passes on as it is. Each other error becomes the fixed text, and
// the log gets a short fixed text only.
export async function friendlyFailure<T>(
  fn: () => Promise<T>,
  fixed: string,
  log: (m: string) => void,
): Promise<T> {
  try {
    return await fn()
  } catch (error) {
    if (error instanceof Error && error.message.startsWith(REFUSAL)) throw error
    log('A Reviews call failed.')
    throw new Error(fixed)
  }
}
