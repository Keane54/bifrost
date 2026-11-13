// The labels of the rows of Settings > Reviews. This list is the one source of the labels: the
// rows use these constants, and the search of Settings finds the rows by them.
export const REVIEWS_ROWS = {
  autoFix: 'Handle comments on my PRs automatically',
  ignore: 'Repositories to ignore',
  maxSessions: 'Maximum PR sessions',
  pauseTime: 'Pause time',
  pollInterval: 'GitHub poll interval',
  removeClones: 'Remove all clones',
  requestModel: 'Model for request sessions',
  reviewModel: 'Model for review sessions',
  signedCommits: 'Sign commits through GitHub',
  teamRequests: 'Show team requests',
  watch: 'Watch GitHub',
} as const
