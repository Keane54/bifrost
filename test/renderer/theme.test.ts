import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = join(__dirname, '../../src/renderer/src')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return sourceFiles(path)
    return /\.tsx?$/.test(entry.name) ? [path] : []
  })
}

const FILES = sourceFiles(SRC).map(path => ({ path, text: readFileSync(path, 'utf8') }))

const TOKENS = [
  'bg',
  'panel',
  'panel-edge',
  'title',
  'section',
  'text',
  'text-dim',
  'text-strong',
  'select',
  'hover',
  'snap',
]

describe('theme', () => {
  it.each(TOKENS)('defines --color-%s', token => {
    expect(CSS).toMatch(new RegExp(`--color-${token}:`))
  })

  it('has no accent token', () => {
    expect(CSS).not.toContain('--color-accent')
  })

  it('has no hex colour or rgb( in a .ts or .tsx file', () => {
    const bad = FILES.filter(f => /#[0-9a-fA-F]{3,8}\b|rgba?\(/.test(f.text)).map(f => f.path)
    expect(bad).toEqual([])
  })

  it('has no accent class in any file', () => {
    const bad = FILES.filter(f => /accent/i.test(f.text)).map(f => f.path)
    expect(bad).toEqual([])
  })
})
