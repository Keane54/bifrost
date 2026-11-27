// Two lines the module logs as it starts. The check app reads them from the host's log lines to
// prove the host gives a module no network, no workers, no Node and no way to load more code.

const GLOBALS = ['fetch', 'XMLHttpRequest', 'WebSocket', 'Worker', 'require', 'process']

// A module that needs nothing else, so any engine with a working loader can import it. If the
// import is refused, it's because the engine has no loader, not because the module is missing.
export const IMPORT_PROBE = 'data:text/javascript,export default 1'

// One line, "globals " and then the typeof of each name as JSON, so every value should read
// "undefined" in the host. The names are looked up on globalThis because the bundler swaps a bare
// require for a stand-in of its own, which is a function.
export function logGlobals(): void {
  const scope = globalThis as Record<string, unknown>
  const globals = Object.fromEntries(GLOBALS.map(name => [name, typeof scope[name]]))
  console.log('globals ' + JSON.stringify(globals))
}

// Tries to import IMPORT_PROBE and logs "import allowed" or "import rejected: " and the reason once
// the try has settled. An engine can refuse by throwing straight away or by rejecting the promise,
// and both count as rejected. The specifier is passed in so the bundler leaves the import alone.
export async function logImportCheck(
  load: (specifier: string) => Promise<unknown> = specifier => import(specifier),
): Promise<void> {
  try {
    await load(IMPORT_PROBE)
  } catch (error) {
    console.log('import rejected: ' + (error instanceof Error ? error.message : String(error)))
    return
  }
  console.log('import allowed')
}

// Logs the globals line, starts the import check and renders straight away, so an import that
// never settles can't hold back the first tree. The import line comes whenever the check is done.
export function start(render: () => void, load?: (specifier: string) => Promise<unknown>): void {
  logGlobals()
  void logImportCheck(load)
  render()
}
