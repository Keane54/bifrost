import { describe, expect, test } from 'vitest'
import { modelName } from '../../../src/main/live/model-name'

describe('modelName', () => {
  test.each([
    ['claude-haiku-5-5', 'Haiku 5.5'],
    ['claude-opus-5-5', 'Opus 5.5'],
    ['claude-sonnet-4-5-20250929', 'Sonnet 4.5'],
    ['claude-opus-4', 'Opus 4'],
    ['claude-opus-5-5[1m]', 'Opus 5.5 (1M context)'],
    ['claude-fable-5-5', 'Fable 5.5'],
  ])('modelName gives the display name for each family (%s)', (id, name) => {
    expect(modelName(id)).toBe(name)
  })

  test.each(['us.anthropic.claude-x-v1:0', 'gpt-5'])(
    'modelName gives the ID for an unknown model (%s)',
    id => {
      expect(modelName(id)).toBe(id)
    },
  )
})
