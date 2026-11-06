// Return true for an object with the Object prototype or no prototype.
// An array, a Map, a Date or a class instance is not a plain object.
export function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const proto = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}
