import type { BifrostApi } from '../shared/api'

declare global {
  interface Window {
    bifrost: BifrostApi
  }
}
