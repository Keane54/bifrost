import { describe, expect, it } from 'vitest'
import { fetchMergedPrs, mergedPrsArgs } from '../../../src/main/daily-update/merged-prs'
import type { Gh } from '../../../src/main/reviews/gh'

const ok = (stdout: string) => ({ code: 0, stderr: '', stdout })
const fakeGh = (result: Awaited<ReturnType<Gh['run']>>): Gh & { calls: string[][] } => {
  const calls: string[][] = []
  return {
    calls,
    async run(args) {
      calls.push(args)
      return result
    },
  }
}

describe('mergedPrsArgs', () => {
  it('builds the search arguments', () => {
    expect(mergedPrsArgs('2026-11-10T09:00:00Z')).toEqual([
      'search',
      'prs',
      '--author=@me',
      '--merged-at=>=2026-11-10T09:00:00Z',
      '--limit',
      '100',
      '--json',
      'number,title,url,repository,closedAt,body',
    ])
  })
})

describe('fetchMergedPrs', () => {
  it('maps closedAt to mergedAt and cuts the body', async () => {
    const gh = fakeGh(
      ok(
        JSON.stringify([
          {
            body: 'x'.repeat(3000),
            closedAt: '2026-11-10T10:00:00Z',
            number: 7,
            repository: { name: 'bifrost', nameWithOwner: 'acme/bifrost' },
            title: 'Fix it',
            url: 'https://github.com/acme/bifrost/pull/7',
          },
        ]),
      ),
    )
    const out = await fetchMergedPrs(gh, '2026-11-10T09:00:00Z')
    expect(gh.calls[0]).toEqual(mergedPrsArgs('2026-11-10T09:00:00Z'))
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(out.prs).toHaveLength(1)
    const [pr] = out.prs
    expect(pr?.mergedAt).toBe('2026-11-10T10:00:00Z')
    expect(pr?.repo).toBe('acme/bifrost')
    expect(pr?.number).toBe(7)
    expect(pr?.body.startsWith('x'.repeat(2000))).toBe(true)
    expect(pr?.body.length).toBeLessThan(2100)
  })

  it('drops an item with a missing or wrong-typed field', async () => {
    const good = {
      body: '',
      closedAt: 't',
      number: 1,
      repository: { nameWithOwner: 'a/b' },
      title: 'T',
      url: 'u',
    }
    const gh = fakeGh(
      ok(JSON.stringify([good, { ...good, number: '2' }, { ...good, title: null }, 5])),
    )
    const out = await fetchMergedPrs(gh, 's')
    expect(out.ok && out.prs.map(p => p.number)).toEqual([1])
  })

  it('treats a null body as empty text', async () => {
    const gh = fakeGh(
      ok(
        JSON.stringify([
          {
            body: null,
            closedAt: 't',
            number: 1,
            repository: { nameWithOwner: 'a/b' },
            title: 'T',
            url: 'u',
          },
        ]),
      ),
    )
    const out = await fetchMergedPrs(gh, 's')
    expect(out.ok && out.prs[0]?.body).toBe('')
  })

  it('gives the gh reason on a failure', async () => {
    const gh = fakeGh({ code: 1, stderr: 'boom\nmore', stdout: '' })
    expect(await fetchMergedPrs(gh, 's')).toEqual({ ok: false, reason: 'boom' })
  })

  it('fails on output that is not a JSON list', async () => {
    expect((await fetchMergedPrs(fakeGh(ok('nope')), 's')).ok).toBe(false)
    expect((await fetchMergedPrs(fakeGh(ok('{}')), 's')).ok).toBe(false)
  })
})
