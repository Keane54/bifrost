// A function that runs fn at the first call only. Later calls do nothing.
export function once(fn: () => void): () => void {
  let done = false
  return () => {
    if (done) return
    done = true
    fn()
  }
}
