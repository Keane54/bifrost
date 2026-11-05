// The stdout of "claude rm abd71478" for a worktree with a commit on no remote. It is the
// real output of Claude Code 2.1.318, from docs/m4-findings.md ("Controller check: claude rm of
// a worktree with a commit", step 5). The exit code was 1.
// The source holds no em dash, so the special characters are written as codes.
const DASH = String.fromCharCode(0x2014)
const OPEN_QUOTE = String.fromCharCode(0x201c)
const CLOSE_QUOTE = String.fromCharCode(0x201d)

// The short ID, the worktree and the HEAD commit of the worktree in the output.
export const KEPT_SHORT_ID = 'abd71478'
export const KEPT_WORKTREE =
  '/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-rmx'
export const KEPT_HEAD = 'f7698d38614ba22b41f996fab73124361d2fe389'

// The value of --discard-unpushed in the output. The first part is the HEAD commit.
export const KEPT_DISCARD = `${KEPT_HEAD}@598a160a880168020f78fdeda23f998a`

export const KEPT_STDOUT = [
  `kept abd71478 ${DASH} its worktree is still at ${OPEN_QUOTE}/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-rmx${CLOSE_QUOTE}`,
  `  169 unpushed commits on ${OPEN_QUOTE}worktree-bifrost-test-rmx${CLOSE_QUOTE}: f7698d3 ${OPEN_QUOTE}test: bifrost-test commit${CLOSE_QUOTE} and 168 more. They exist on no remote, so deleting the worktree would lose them.`,
  `  push them and run 'claude rm abd71478' again, or discard the worktree and its commits: claude rm abd71478 --discard-unpushed ${KEPT_DISCARD}`,
  '',
].join('\n')
