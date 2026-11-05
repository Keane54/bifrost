// The text of a failure: the message of an Error, or the value as text.
export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
