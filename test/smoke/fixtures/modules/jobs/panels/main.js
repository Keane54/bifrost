// The jobs module. It asks Heimdall for one module job, and it counts the refresh events. It
// writes each result into the page, and the smoke test reads it. The input holds a fake token,
// so the test can check that the token does not get to claude.
;(async () => {
  const show = (id, text) => {
    document.getElementById(id).textContent = text
  }
  if (typeof globalThis.bifrost !== 'object') {
    show('job', 'no client library')
    return
  }
  let refreshes = 0
  bifrost.on('refresh', () => {
    refreshes += 1
    show('refreshed', `refreshed: ${refreshes}`)
  })
  const token = ['ghp', 'A1b2C3d4E5f6G7h8I9j0'].join('_')
  show('job', 'asked')
  try {
    const result = await bifrost.call('claude.job', {
      input: `The input. ${token}`,
      prompt: 'Say hello.',
    })
    show('job', `job: ${result.text}`)
  } catch (error) {
    show('job', `failed: ${error.message}`)
  }
})()
