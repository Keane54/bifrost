// The hello module. It loads the client library of Bifrost, and it calls Heimdall through the
// bridge of its panel. It writes each result into the page, and the smoke test reads it.
;(async () => {
  const show = (id, text) => {
    document.getElementById(id).textContent = text
  }
  if (typeof globalThis.bifrost !== 'object') {
    show('stored', 'no client library')
    return
  }
  try {
    await bifrost.call('storage.set', { key: 'greeting', value: { text: 'hello from Heimdall' } })
    const value = await bifrost.call('storage.get', { key: 'greeting' })
    show('stored', `stored: ${value?.text}`)
  } catch (error) {
    show('stored', `failed: ${error.message}`)
  }
  // The module did not ask for notify, so Heimdall refuses the call.
  try {
    await bifrost.call('notify', { title: 'Hello' })
    show('refused', 'allowed')
  } catch (error) {
    show('refused', error.message)
  }
})()
