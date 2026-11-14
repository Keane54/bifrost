// The greeter module. The smoke test installs it from a folder and allows it. Its panel saves a
// value in its own storage, reads it back, and asks Heimdall for a notification. It writes each
// result into the page, and the smoke test reads it.
;(async () => {
  const show = (id, text) => {
    document.getElementById(id).textContent = text
  }
  if (typeof globalThis.bifrost !== 'object') {
    show('stored', 'no client library')
    return
  }
  try {
    await bifrost.call('storage.set', { key: 'greeting', value: { text: 'hello again' } })
    const value = await bifrost.call('storage.get', { key: 'greeting' })
    show('stored', `stored: ${value?.text}`)
  } catch (error) {
    show('stored', `failed: ${error.message}`)
  }
  try {
    await bifrost.call('notify', { body: 'The panel is open.', title: 'Hello' })
    show('notified', 'notified')
  } catch (error) {
    show('notified', error.message)
  }
})()
