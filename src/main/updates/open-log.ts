// The Show log button. It opens the update log in its default app. Each failure reaches the
// page as a rejection, so the page can show a message. A silent failure is a dead button.
export const UPDATE_LOG_TEXTS = {
  none: "Bifrost isn't keeping an update log in this build.",
  unreadable: "Bifrost couldn't open the update log. Check the permissions of the Logs folder.",
}

export interface OpenLogDeps {
  // Make the file when it does not exist, so the open finds a file.
  ensureFile(path: string): Promise<void>
  // Resolves with an error text, or an empty text when the open works.
  openPath(path: string): Promise<string>
  showItemInFolder(path: string): void
}

export async function openUpdateLog(path: string | null, deps: OpenLogDeps): Promise<void> {
  if (path === null) throw new Error(UPDATE_LOG_TEXTS.none)
  try {
    await deps.ensureFile(path)
  } catch {
    throw new Error(UPDATE_LOG_TEXTS.unreadable)
  }
  const error = await deps.openPath(path)
  // No app opened the file. Show the file in Finder, so the user can still reach it.
  if (error) deps.showItemInFolder(path)
}
