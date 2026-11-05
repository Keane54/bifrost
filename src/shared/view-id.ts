// The view ID of the chat window of a session: "chat:" and the session ID (8-4-4-4-12 hex digits).
// The main process and the renderer use this one pattern.
export const CHAT_VIEW = /^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
