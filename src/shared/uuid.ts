export const UUID_PATTERN =
  '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

const UUID = new RegExp(UUID_PATTERN)

// True when the value is a string in the form of a UUID.
export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID.test(value)
}
