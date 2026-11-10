// The stdout of "claude rm abd71478" for a worktree with a commit on no remote. It is the
// real output of Claude Code 2.1.318, from a real run of claude rm on a worktree with a commit.
// The exit code was 1.
// The source holds no em dash, so the special characters are written as codes.
const DASH = String.fromCharCode(0x2014)
const OPEN_QUOTE = String.fromCharCode(0x201c)
const CLOSE_QUOTE = String.fromCharCode(0x201d)

// The short ID, the worktree and the HEAD commit of the worktree in the output.
export const KEPT_SHORT_ID = 'abd71478'
export const KEPT_WORKTREE = '/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-rmx'
export const KEPT_HEAD = 'f7698d38614ba22b41f996fab73124361d2fe389'

// The value of --discard-unpushed in the output. The first part is the HEAD commit.
export const KEPT_DISCARD = `${KEPT_HEAD}@598a160a880168020f78fdeda23f998a`

export const KEPT_STDOUT = [
  `kept abd71478 ${DASH} its worktree is still at ${OPEN_QUOTE}/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-rmx${CLOSE_QUOTE}`,
  `  169 unpushed commits on ${OPEN_QUOTE}worktree-bifrost-test-rmx${CLOSE_QUOTE}: f7698d3 ${OPEN_QUOTE}test: bifrost-test commit${CLOSE_QUOTE} and 168 more. They exist on no remote, so deleting the worktree would lose them.`,
  `  push them and run 'claude rm abd71478' again, or discard the worktree and its commits: claude rm abd71478 --discard-unpushed ${KEPT_DISCARD}`,
  '',
].join('\n')

// The stdout of "claude rm 27b87cbf" for a worktree with uncommitted changes (Task 17 bug 2). A real
// run of Claude Code gave the text after the kept line and the dash (U+2014). The kept line and the line breaks have the form of the output above. The short ID
// and the worktree are the ones of bifrost-test-wt1 (Task 17 bug 1). The output has no
// --discard-unpushed value.
export const CHANGES_SHORT_ID = '27b87cbf'
export const CHANGES_WORKTREE =
  '/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-wt1'

export const CHANGES_STDOUT = [
  `kept 27b87cbf ${DASH} its worktree is still at ${OPEN_QUOTE}/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-wt1${CLOSE_QUOTE}`,
  '  The worktree has uncommitted changes. Deleting it would lose them.',
  "  commit or stash them and run 'claude rm 27b87cbf' again, or delete the session from 'claude agents' (ctrl+x twice)",
  '',
].join('\n')
