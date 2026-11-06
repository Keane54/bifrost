// The values of Live details that the main process and the renderer both use.
// This file imports nothing.

// Live details needs this version of Claude Code or later (spec 11.2, 11.5).
export const LIVE_MIN_CLAUDE_VERSION = '2.1.290'

// The message of a Live details action that comes while another action runs (spec 11.2).
export const BUSY_MESSAGE = 'Another change is still running. Try again in a moment.'
