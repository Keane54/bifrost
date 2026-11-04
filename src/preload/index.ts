import { contextBridge } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

// This object holds the custom APIs for the renderer.
const api = {}

// With context isolation, the preload script uses `contextBridge` to expose the APIs.
// Without context isolation, it adds the APIs to the window object.
if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', electronAPI)
    contextBridge.exposeInMainWorld('api', api)
  } catch (error) {
    console.error(error)
  }
} else {
  // @ts-ignore (define in dts)
  window.electron = electronAPI
  // @ts-ignore (define in dts)
  window.api = api
}
