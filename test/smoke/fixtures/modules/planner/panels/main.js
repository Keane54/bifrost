// The planner module. It asks Heimdall to open Discuss with Claude, with one card. The card text
// holds a zero-width space, so the test can check that the copy removes it. The module writes the
// answer of Heimdall into the page, and the smoke test reads it.
;(async () => {
  const show = text => {
    document.getElementById('asked').textContent = text
  }
  if (typeof globalThis.bifrost !== 'object') {
    show('no client library')
    return
  }
  try {
    const value = await bifrost.call('discuss.request', {
      cards: [{ label: 'This week', text: 'Ship the\u200B release notes.' }],
      title: 'Plan the week',
    })
    show(`asked: ${JSON.stringify(value)}`)
  } catch (error) {
    show(`failed: ${error.message}`)
  }
})()
