// The URLs of module files (Modules design 8.1). The main process and the renderer both use them.

export const MODULE_SCHEME = 'bifrost-module'

const MODULE_URL = /^bifrost-module:/i

// The URL of a file of a module. The host is the module id. Each path segment is encoded, so a
// file name with "#", "?" or "%" stays one name.
export function moduleUrl(id: string, path: string): string {
  return `${MODULE_SCHEME}://${id}/${path.split('/').map(encodeURIComponent).join('/')}`
}

export function isModuleUrl(url: unknown): boolean {
  return typeof url === 'string' && MODULE_URL.test(url)
}
