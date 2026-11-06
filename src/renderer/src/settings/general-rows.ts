// The labels of the rows of Settings > General (spec 12). This list is the one source of the
// labels: the rows use these constants, and the search of Settings finds the rows by them.
// To add a row, add one line here, and give the row the label GENERAL_ROWS.<name>. A test fails
// on a row label in another form, also in a file that GeneralSection.tsx imports.
export const GENERAL_ROWS = {
  displayMode: 'Display mode',
  escalation: 'Escalation time',
  font: 'Terminal font',
  introduction: 'Introduction',
  labels: 'Labels',
  notifications: 'macOS notification',
  poll: 'Poll interval',
  projectApp: 'Default app for "Open project"',
  redBoxSound: 'Sound for a red box',
  rowFlash: 'Row flash',
  scale: 'Interface scale',
  snap: 'Snap distance',
  startAtLogin: 'Start at login',
  terminalApp: 'Terminal app',
  transparency: 'Panel transparency',
} as const
