// The Refresh button of a module panel (plan Task 8). It is part of the title bar of Bifrost,
// outside the frame. It shows for an enabled module with waiting jobs and no claude-jobs-auto.
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import {
  MODULE_REFRESH_TIP,
  ModuleRefreshView,
  moduleRefreshTarget,
  moduleTierLabel,
  refreshModule,
} from '../../../src/renderer/src/modules/ModuleRefresh'
import type { ModuleRow } from '../../../src/shared/modules'

function row(over: Partial<ModuleRow> = {}): ModuleRow {
  return {
    dailyCap: 50,
    description: 'Says hello.',
    dev: false,
    enabled: true,
    granted: ['claude-jobs'],
    id: 'hello',
    jobsToday: 0,
    model: 'sonnet',
    name: 'Hello',
    offReason: null,
    panels: [{ entry: 'panels/main.html', icon: 'star', id: 'main', title: 'Hello board' }],
    pendingUpdate: null,
    requested: [],
    source: '~/Developer/hello',
    sourceKind: 'folder',
    tier: 'standard',
    version: '1.0.0',
    waitingJobs: 2,
    ...over,
  }
}

const MAIN = 'module:hello:main'

describe('moduleRefreshTarget', () => {
  it('gives the module with waiting jobs and the count', () => {
    expect(moduleRefreshTarget([row()], MAIN)).toEqual({ moduleId: 'hello', waiting: 2 })
  })

  it('gives a count of 0 for a module with no waiting job', () => {
    expect(moduleRefreshTarget([row({ waitingJobs: 0 })], MAIN)).toEqual({
      moduleId: 'hello',
      waiting: 0,
    })
  })

  it('gives the module with claude-jobs-auto too (the refresh event goes to both modes)', () => {
    const granted = ['claude-jobs', 'claude-jobs-auto'] as ModuleRow['granted']
    expect(moduleRefreshTarget([row({ granted, waitingJobs: 0 })], MAIN)).toEqual({
      moduleId: 'hello',
      waiting: 0,
    })
  })

  it('gives nothing for a module without claude-jobs', () => {
    expect(moduleRefreshTarget([row({ granted: [] })], MAIN)).toBeNull()
  })

  it('gives nothing for a module that is off, gone, or not a module panel', () => {
    expect(moduleRefreshTarget([row({ enabled: false })], MAIN)).toBeNull()
    expect(moduleRefreshTarget([], MAIN)).toBeNull()
    expect(moduleRefreshTarget([row()], 'module:hello:none')).toBeNull()
    expect(moduleRefreshTarget([row()], 'overview')).toBeNull()
  })
})

describe('ModuleRefreshView', () => {
  const html = (waiting: number): string =>
    renderToStaticMarkup(
      createElement(ModuleRefreshView, { moduleId: 'hello', onRefresh: () => {}, waiting }),
    )

  it('shows the button with the count and the tip', () => {
    const out = html(2)
    expect(out).toContain('Refresh')
    expect(out).toContain('Refresh</span><span data-module-waiting="true"> · 2 waiting')
    expect(out).toContain('· 2 waiting')
    expect(out).toContain(`title="${MODULE_REFRESH_TIP}"`)
    expect(out).toContain('data-module-refresh="hello"')
    expect(out).toContain('transition-colors duration-150')
  })

  it('has a tip in friendly English', () => {
    expect(MODULE_REFRESH_TIP).toBe('Run the waiting module jobs')
  })
})

describe('ModuleRefreshView with no waiting job', () => {
  it('shows a plain Refresh with no count', () => {
    const out = renderToStaticMarkup(
      createElement(ModuleRefreshView, { moduleId: 'hello', onRefresh: () => {}, waiting: 0 }),
    )
    expect(out).toContain('Refresh')
    expect(out).not.toContain('data-module-waiting')
  })
})

describe('the click', () => {
  it('calls onRefresh from the button', () => {
    const onRefresh = vi.fn()
    const element = ModuleRefreshView({ moduleId: 'hello', onRefresh, waiting: 1 })
    ;(element.props as { onClick(): void }).onClick()
    expect(onRefresh).toHaveBeenCalledTimes(1)
  })

  it('calls modules.refresh with the module id', async () => {
    const refresh = vi.fn(async () => {})
    refreshModule({ refresh }, 'hello', () => {})
    expect(refresh).toHaveBeenCalledWith('hello')
  })

  it('logs a refusal with a short text and does not throw', async () => {
    const log = vi.fn()
    const error = new Error('refused: unknown module')
    refreshModule({ refresh: () => Promise.reject(error) }, 'hello', log)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).toHaveBeenCalledWith('Bifrost cannot refresh the module.', error)
  })
})

describe('the tier badge', () => {
  it('says Standard or Permissive', () => {
    expect(moduleTierLabel('standard')).toBe('Standard')
    expect(moduleTierLabel('permissive')).toBe('Permissive')
  })
})
