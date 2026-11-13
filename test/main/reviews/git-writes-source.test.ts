// The only git write to GitHub is the push of a fix in reviews/request-push.ts. It pushes one
// commit to the head branch of the PR, with no form of force. This test reads each .ts file of
// src/main and fails when a push call shows up in another file or another form. A deny rule of a
// session, such as Bash(git push:*), names the command and does not run it, so it is allowed.
// If a pattern finds a harmless text in a file, make the pattern more exact. Never remove a
// pattern.

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const MAIN = fileURLToPath(new URL('../../../src/main/', import.meta.url))
// The path of each file is relative to src/main, with forward slashes.
const PUSHER = 'reviews/request-push.ts'

// The parts of the push list pattern. \x60 is the backtick.
const QUOTED = String.raw`(?:'[^'\n]*'|"[^"\n]*"|\x60[^\x60]*\x60)`
const ITEM = String.raw`(?:${QUOTED}|[\w.$]+)`
const FLAG = String.raw`(?:'-[^'\n]*'|"-[^"\n]*"|\x60-[^\x60]*\x60)`
const SPREAD = String.raw`\.\.\.[\w.$]+`
// -c and -C take a value: a config item or a folder.
const VALUE_FLAG = String.raw`(?:'-[cC]'|"-[cC]"|\x60-[cC]\x60)\s*,\s*${ITEM}`
const PUSH_ITEM = String.raw`(?:'push'|"push"|\x60push\x60)`
// The start of a push list: an array, or a push, unshift or concat call, with only git options
// before the item 'push'. An option is a flag, -c or -C with its value, or a spread. A bracket
// right after a name or a bracket is an index, as in FixPusher['push'], and not an array.
const PUSH_LIST = new RegExp(
  String.raw`(?:(?<![\w$\])])\[|\.(?:push|unshift|concat)\()\s*` +
    String.raw`(?:(?:${VALUE_FLAG}|${FLAG}|${SPREAD})\s*,\s*)*${PUSH_ITEM}(?=\s*[,\])])`,
  'g',
)
// The push of the plan, with no white space. The two values are names.
const EXACT = new RegExp(
  String.raw`^\['push','--porcelain','--no-follow-tags','--recurse-submodules=no','origin',` +
    String.raw`\x60\$\{[\w.]+\}:refs\/heads\/\$\{[\w.]+\}\x60,?\]$`,
)
// A quoted item that starts with + (a forced refspec) or : (a delete refspec).
const PLUS_OR_COLON = /[[(,]\s*['"`][+:]/
// A quoted item that forces, deletes, or pushes more than one ref. A short flag can be in a group
// with other short flags, as in -uf.
const FORCE_FLAG = new RegExp(
  String.raw`['"\x60](?:--force[\w-]*|--delete|--all|--tags|--prune|--mirror|` +
    String.raw`-[A-Za-z]*[fd][A-Za-z]*)(?:=[^'"\x60]*)?['"\x60]`,
)
// The text git push, also with options between git and push, but not in a deny rule.
const GIT_PUSH = /(?<!Bash\()\bgit(?:\s+-\S+(?:\s+[^\s-]\S*)?)*\s+push(?![\w.-])/

// The index after the quote that closes the quoted text that starts at start.
function afterQuote(code: string, start: number): number {
  const quote = code[start]
  for (let i = start + 1; i < code.length; i++) {
    if (code[i] === '\\') i++
    else if (code[i] === quote) return i + 1
  }
  return code.length
}

// The index of the bracket that closes the list that opens at open. A quoted text is skipped.
function closeOf(code: string, open: number): number {
  let depth = 0
  let i = open
  while (i < code.length) {
    const c = code[i] as string
    if (c === "'" || c === '"' || c === '`') {
      i = afterQuote(code, i)
      continue
    }
    if ('[({'.includes(c)) depth++
    if (')]}'.includes(c)) {
      depth--
      if (depth === 0) return i
    }
    i++
  }
  return code.length
}

// The text of each push list, from its opening bracket to its closing bracket.
function pushLists(code: string): string[] {
  return [...code.matchAll(PUSH_LIST)].map(match => {
    const open = (match.index ?? 0) + match[0].search(/[[(]/)
    return code.slice(open, closeOf(code, open) + 1)
  })
}

const RULE = {
  command: 'send-pack, http-push or a git alias',
  flag: 'a force, delete, all, tags, prune or mirror flag in a push list',
  form: 'a push list in request-push.ts that is not the push of the plan',
  lease: '--force-with-lease, --force-if-includes or --mirror',
  outside: 'a push list outside request-push.ts',
  refspec: 'a push item that starts with + or :',
  text: 'the text git push outside a deny rule',
} as const

interface Rule {
  name: string
  finds(code: string, file: string): boolean
}

const RULES: Rule[] = [
  { finds: (code, file) => file !== PUSHER && pushLists(code).length > 0, name: RULE.outside },
  {
    finds: (code, file) =>
      file === PUSHER && pushLists(code).some(list => !EXACT.test(list.replace(/\s+/g, ''))),
    name: RULE.form,
  },
  { finds: code => pushLists(code).some(list => PLUS_OR_COLON.test(list)), name: RULE.refspec },
  { finds: code => pushLists(code).some(list => FORCE_FLAG.test(list)), name: RULE.flag },
  {
    finds: code => /--force-with-lease|--force-if-includes|--mirror\b/.test(code),
    name: RULE.lease,
  },
  { finds: code => GIT_PUSH.test(code), name: RULE.text },
  {
    finds: code => /['"`](?:send-pack|http-push)\b|\balias\.[\w-]+=/.test(code),
    name: RULE.command,
  },
]

// A full-line comment is not code, so the rules do not read it.
function codeOf(text: string): string {
  return text
    .split('\n')
    .filter(line => !line.trim().startsWith('//'))
    .join('\n')
}

function ruleNames(text: string, file: string): string[] {
  const code = codeOf(text)
  return RULES.filter(rule => rule.finds(code, file)).map(rule => rule.name)
}

function sourceFiles(): string[] {
  return readdirSync(MAIN, { recursive: true })
    .map(entry => String(entry).split('\\').join('/'))
    .filter(entry => /\.tsx?$/.test(entry))
    .sort()
}

describe('git writes in src/main', () => {
  it('reads the files of src/main, with request-push.ts and repo-store.ts', () => {
    const files = sourceFiles()
    expect(files).toContain(PUSHER)
    expect(files).toContain('reviews/repo-store.ts')
    expect(files.length).toBeGreaterThan(50)
  })

  it('has no push outside request-push.ts, and no form of force', () => {
    const found = sourceFiles().flatMap(file =>
      ruleNames(readFileSync(join(MAIN, file), 'utf8'), file).map(name => `${file}: ${name}`),
    )
    expect(found).toEqual([])
  })

  it('request-push.ts has the push of the plan exactly one time', () => {
    const lists = pushLists(codeOf(readFileSync(join(MAIN, PUSHER), 'utf8')))
    expect(lists).toHaveLength(1)
    expect(lists[0]?.replace(/\s+/g, '')).toMatch(EXACT)
  })
})

// A sample text writes % for the $ of a placeholder. So the sample is not a string with a
// placeholder in it, which the linter refuses.
const tpl = (text: string): string => text.replaceAll('%', '$')
const PLAN =
  "run(['push', '--porcelain', '--no-follow-tags', '--recurse-submodules=no', 'origin', " +
  '`%{sha}:refs/heads/%{headRef}`])'
const PLAN_PUSH = tpl(PLAN)
// The push of the plan with one more item before the refspec.
const pushWith = (item: string): string =>
  tpl(
    "run(['push', '--porcelain', '--no-follow-tags', '--recurse-submodules=no', 'origin', " +
      `${item}, \`%{sha}:refs/heads/%{headRef}\`])`,
  )

// Each bad text names the rule that must find it. So one rule cannot hide a broken other rule.
describe('the rules', () => {
  const bad: [string, string, string][] = [
    [RULE.outside, "git.run(['push', 'origin', ref])", 'reviews/x.ts'],
    [
      RULE.outside,
      tpl("deps.git.run([`--git-dir=%{dir}`, 'push', 'origin', ref])"),
      'reviews/x.ts',
    ],
    [RULE.outside, "git.run(['-C', dir, '-c', 'a=b', 'push', 'origin'])", 'live/x.ts'],
    [RULE.outside, "args.push('push', 'origin', ref)", 'reviews/x.ts'],
    [RULE.outside, "execFile('git', [...GIT_CONFIG, \"push\", 'origin'])", 'info/x.ts'],
    [RULE.outside, PLAN_PUSH, 'reviews/request-writes.ts'],
    [RULE.form, tpl("run(['push', 'origin', `%{sha}:refs/heads/%{headRef}`])"), PUSHER],
    [RULE.form, pushWith("'--atomic'"), PUSHER],
    [RULE.form, `${PLAN_PUSH}\n${tpl("run(['push', 'origin', ref])")}`, PUSHER],
    [RULE.refspec, tpl(PLAN.replace('`%{sha}', '`+%{sha}')), PUSHER],
    [RULE.refspec, tpl("run(['push', 'origin', `:refs/heads/%{headRef}`])"), PUSHER],
    [RULE.refspec, "git.run(['push', 'origin', '+main'])", 'reviews/x.ts'],
    ...['--force', '-f', '--delete', '-d', '--all', '--tags', '--prune', '-uf'].map(
      (flag): [string, string, string] => [RULE.flag, pushWith(`'${flag}'`), PUSHER],
    ),
    [RULE.flag, pushWith("'--force-with-lease=main'"), PUSHER],
    [RULE.lease, "const FLAGS = ['--force-with-lease']", 'reviews/x.ts'],
    [RULE.lease, "const FLAGS = ['--force-if-includes']", 'reviews/x.ts'],
    [RULE.lease, "git.run(['clone', '--mirror', url])", 'reviews/x.ts'],
    [RULE.text, "execFile('/bin/sh', ['-c', 'git push origin main'])", 'live/x.ts'],
    [RULE.text, "const command = 'git -C /tmp/x push --force'", 'reviews/x.ts'],
    [RULE.text, 'const line = "git push"', 'reviews/x.ts'],
    [RULE.command, "git.run(['send-pack', url, 'main'])", 'reviews/x.ts'],
    [RULE.command, "git.run(['http-push', url, 'main'])", 'reviews/x.ts'],
    [RULE.command, "git.run(['-c', 'alias.up=push', 'up', 'origin'])", 'reviews/x.ts'],
  ]
  it.each(bad)('%s finds %j in %s', (rule, text, file) => {
    expect(ruleNames(text, file)).toContain(rule)
  })

  it('has a bad text for each rule', () => {
    const named = new Set(bad.map(([rule]) => rule))
    expect(RULES.map(rule => rule.name).filter(name => !named.has(name))).toEqual([])
  })

  const harmless: [string, string][] = [
    [PLAN_PUSH, PUSHER],
    [
      "await gitIn(clone, ['worktree', 'remove', '--force', '--force', path])",
      'reviews/repo-store.ts',
    ],
    [
      tpl(
        "['fetch', '--quiet', '--no-tags', '--', 'origin', `+refs/pull/%{number}/head:%{prRef}`]",
      ),
      'reviews/repo-store.ts',
    ],
    [
      tpl("['fetch', '--quiet', '--no-tags', '--', 'origin', `+refs/heads/%{headRef}:%{local}`]"),
      PUSHER,
    ],
    ["const NO_PUSH_SIGN = ['-c', 'push.gpgSign=false']", PUSHER],
    ["type PushInput = Parameters<FixPusher['push']>[0]", PUSHER],
    ["git.run(['config', '--get-all', 'remote.origin.pushurl'])", PUSHER],
    ["  | { kind: 'push'; sha?: string }", 'reviews/state.ts'],
    ["    case 'push':", 'reviews/state.ts'],
    ["const DENY = ['Bash(git push:*)', 'Bash(git commit:*)', 'Bash(gh:*)']", 'reviews/x.ts'],
    ["out.push(line)\nargs.push('--no-tags')", 'reviews/x.ts'],
    ["const KINDS = ['commit', 'push', 'reply']", 'reviews/x.ts'],
    ['// The push of a fix runs git push with no force.', 'reviews/x.ts'],
  ]
  it.each(harmless)('ignores %j in %s', (text, file) => {
    expect(ruleNames(text, file)).toEqual([])
  })
})
