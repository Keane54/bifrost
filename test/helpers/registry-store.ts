import type { RegistryStore } from '../../src/main/registry/registry'

// A full registry store with empty values. The partial replaces the values that it names.
export function storeOf(partial: Partial<RegistryStore> = {}): RegistryStore {
  return {
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
    ...partial,
  }
}
