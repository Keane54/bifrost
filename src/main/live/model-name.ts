const MODEL_ID = /^claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$/

// Give the display name of a model ID, for example "Opus 5.5".
// Give the ID itself when the ID has an unknown form.
export function modelName(id: string): string {
  const match = MODEL_ID.exec(id)
  if (!match) return id
  const [, family, major, minor, million] = match
  const name = family.charAt(0).toUpperCase() + family.slice(1)
  const version = minor === undefined ? major : `${major}.${minor}`
  return `${name} ${version}${million ? ' (1M context)' : ''}`
}
